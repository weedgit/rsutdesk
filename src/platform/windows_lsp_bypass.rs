//! Keeps Winsock Layered Service Providers (LSPs) out of this process's sockets.
//!
//! Some VPN/proxy clients (seen with Astrill's `ASProxy64.dll`) install an old LSP that
//! crashes when tokio's Windows backend (mio) asks for a socket's base handle
//! (`WSAIoctl(SIO_BASE_HANDLE)`). Every tokio socket does that, so RustDesk crashed at
//! startup while plain-Winsock apps kept working.
//!
//! The fix: when this module creates a socket without naming a provider, it creates it on
//! Microsoft's base provider (`mswsock`, protocol chain length 1). Such a socket never passes
//! through an LSP, so the LSP cannot crash it. Nothing changes system-wide, no admin rights
//! are needed, and other programs (and the VPN itself) are unaffected.
//!
//! It works by pointing this module's own `WSASocketW` and `socket` imports at the wrappers
//! below. That covers std, socket2, mio/tokio and every other crate linked into this module.
//! Installation runs as a CRT initializer, before any Rust code can open a socket. It only
//! rewrites import slots there; the provider catalog is read lazily on the first socket call,
//! outside the loader lock.

use std::{
    ffi::c_void,
    sync::{
        atomic::{AtomicUsize, Ordering},
        OnceLock,
    },
};

type Socket = usize;
const INVALID_SOCKET: Socket = !0;
const SOCKET_ERROR: i32 = -1;
const BASE_PROTOCOL: i32 = 1;
const PFL_MATCHES_PROTOCOL_ZERO: u32 = 0x0000_0008;
const WSA_FLAG_OVERLAPPED: u32 = 0x01;
const PAGE_READWRITE: u32 = 0x04;
const GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT: u32 = 0x2;
const GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS: u32 = 0x4;

#[repr(C)]
#[derive(Clone, Copy)]
struct Guid {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [u8; 8],
}

#[repr(C)]
#[derive(Clone, Copy)]
struct ProtocolChain {
    chain_len: i32,
    chain_entries: [u32; 7],
}

/// `WSAPROTOCOL_INFOW` from winsock2.h.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct ProtocolInfo {
    service_flags: [u32; 4],
    provider_flags: u32,
    provider_id: Guid,
    catalog_entry_id: u32,
    protocol_chain: ProtocolChain,
    version: i32,
    address_family: i32,
    max_sockaddr: i32,
    min_sockaddr: i32,
    socket_type: i32,
    protocol: i32,
    protocol_max_offset: i32,
    network_byte_order: i32,
    security_scheme: i32,
    message_size: u32,
    provider_reserved: u32,
    sz_protocol: [u16; 256],
}

type WsaSocketWFn =
    unsafe extern "system" fn(i32, i32, i32, *const ProtocolInfo, u32, u32) -> Socket;
type SocketFn = unsafe extern "system" fn(i32, i32, i32) -> Socket;

#[link(name = "ws2_32")]
extern "system" {
    fn WSAEnumProtocolsW(protocols: *const i32, buffer: *mut ProtocolInfo, len: *mut u32) -> i32;
}

#[link(name = "kernel32")]
extern "system" {
    fn GetModuleHandleExW(flags: u32, name: *const u16, module: *mut *mut c_void) -> i32;
    fn GetModuleHandleW(name: *const u16) -> *mut c_void;
    fn GetProcAddress(module: *mut c_void, name: *const u8) -> *mut c_void;
    fn VirtualProtect(addr: *mut c_void, size: usize, new: u32, old: *mut u32) -> i32;
}

/// The real functions, saved before their import slots are redirected.
static REAL_WSASOCKETW: AtomicUsize = AtomicUsize::new(0);
static REAL_SOCKET: AtomicUsize = AtomicUsize::new(0);
/// How many import slots were redirected, for the startup log.
static PATCHED: AtomicUsize = AtomicUsize::new(0);
/// How many sockets were moved off a layered provider, for the log.
static BYPASSED: AtomicUsize = AtomicUsize::new(0);

/// Runs while the module loads, before `main`/`DllMain` user code.
#[used]
#[link_section = ".CRT$XCU"]
static INSTALL_AT_LOAD: unsafe extern "C" fn() = install_at_load;

unsafe extern "C" fn install_at_load() {
    install();
}

/// Redirects this module's `WSASocketW`/`socket` imports. Safe to call more than once.
pub fn install() {
    unsafe {
        let ws2: Vec<u16> = "ws2_32.dll\0".encode_utf16().collect();
        let ws2 = GetModuleHandleW(ws2.as_ptr());
        if ws2.is_null() {
            return;
        }
        let real_wsasocketw = GetProcAddress(ws2, b"WSASocketW\0".as_ptr()) as usize;
        let real_socket = GetProcAddress(ws2, b"socket\0".as_ptr()) as usize;
        if real_wsasocketw == 0 {
            return;
        }
        REAL_WSASOCKETW.store(real_wsasocketw, Ordering::SeqCst);
        REAL_SOCKET.store(real_socket, Ordering::SeqCst);

        let mut module: *mut c_void = std::ptr::null_mut();
        if GetModuleHandleExW(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            install as *const () as *const u16,
            &mut module,
        ) == 0
        {
            return;
        }
        let mut n = patch_slots(module as *const u8, real_wsasocketw, hook_wsasocketw as *const () as usize);
        if real_socket != 0 {
            n += patch_slots(module as *const u8, real_socket, hook_socket as *const () as usize);
        }
        PATCHED.fetch_add(n, Ordering::SeqCst);
    }
}

/// Rewrites every import slot of `module` that holds `target` so it holds `hook` instead.
/// Matching on the resolved address (not the import name) also catches imports by ordinal.
unsafe fn patch_slots(module: *const u8, target: usize, hook: usize) -> usize {
    let rd32 = |off: usize| std::ptr::read_unaligned(module.add(off) as *const u32) as usize;
    if std::ptr::read_unaligned(module as *const u16) != 0x5A4D {
        return 0; // "MZ"
    }
    let nt = rd32(0x3C);
    if rd32(nt) != 0x0000_4550 {
        return 0; // "PE\0\0"
    }
    let optional = nt + 24;
    let magic = std::ptr::read_unaligned(module.add(optional) as *const u16);
    // Data directory 1 is the import table; its offset depends on PE32 vs PE32+.
    let data_dirs = match magic {
        0x20B => optional + 112,
        0x10B => optional + 96,
        _ => return 0,
    };
    let import_rva = rd32(data_dirs + 8);
    if import_rva == 0 {
        return 0;
    }
    let slot_size = std::mem::size_of::<usize>();
    let mut count = 0;
    let mut desc = import_rva;
    loop {
        // IMAGE_IMPORT_DESCRIPTOR: OriginalFirstThunk, TimeDateStamp, ForwarderChain, Name, FirstThunk
        let name = rd32(desc + 12);
        let first_thunk = rd32(desc + 16);
        if name == 0 && first_thunk == 0 {
            break;
        }
        let mut slot = module.add(first_thunk) as *mut usize;
        while *slot != 0 {
            if *slot == target {
                let mut old = 0u32;
                if VirtualProtect(slot as *mut c_void, slot_size, PAGE_READWRITE, &mut old) != 0 {
                    *slot = hook;
                    VirtualProtect(slot as *mut c_void, slot_size, old, &mut old);
                    count += 1;
                }
            }
            slot = slot.add(1);
        }
        desc += 20;
    }
    count
}

/// The provider catalog, read once on first use.
fn catalog() -> &'static [ProtocolInfo] {
    static CATALOG: OnceLock<Vec<ProtocolInfo>> = OnceLock::new();
    CATALOG.get_or_init(|| unsafe {
        let mut len: u32 = 0;
        WSAEnumProtocolsW(std::ptr::null(), std::ptr::null_mut(), &mut len);
        if len == 0 {
            return Vec::new();
        }
        let n = len as usize / std::mem::size_of::<ProtocolInfo>() + 1;
        let mut buf: Vec<ProtocolInfo> = vec![std::mem::zeroed(); n];
        let mut len = (n * std::mem::size_of::<ProtocolInfo>()) as u32;
        let count = WSAEnumProtocolsW(std::ptr::null(), buf.as_mut_ptr(), &mut len);
        if count == SOCKET_ERROR || count < 0 {
            return Vec::new();
        }
        buf.truncate(count as usize);
        buf
    })
}

/// The base provider to use for `(af, ty, proto)`, or `None` to leave the call unchanged
/// (no LSP in front of that kind of socket, or no matching base provider).
fn base_provider(af: i32, ty: i32, proto: i32) -> Option<&'static ProtocolInfo> {
    let cat = catalog();
    let matches = |p: &&ProtocolInfo| {
        p.address_family == af
            && p.socket_type == ty
            && (proto == 0 || p.protocol == proto)
    };
    let layered = cat
        .iter()
        .filter(matches)
        .any(|p| p.protocol_chain.chain_len > BASE_PROTOCOL);
    if !layered {
        return None;
    }
    let mut bases = cat
        .iter()
        .filter(matches)
        .filter(|p| p.protocol_chain.chain_len == BASE_PROTOCOL);
    if proto == 0 {
        let all: Vec<&ProtocolInfo> = bases.collect();
        all.iter()
            .find(|p| p.provider_flags & PFL_MATCHES_PROTOCOL_ZERO != 0)
            .or(all.first())
            .copied()
    } else {
        bases.next()
    }
}

unsafe extern "system" fn hook_wsasocketw(
    af: i32,
    ty: i32,
    proto: i32,
    info: *const ProtocolInfo,
    group: u32,
    flags: u32,
) -> Socket {
    let real: WsaSocketWFn = std::mem::transmute(REAL_WSASOCKETW.load(Ordering::Relaxed));
    if info.is_null() {
        if let Some(base) = base_provider(af, ty, proto) {
            let s = real(af, ty, proto, base, group, flags);
            if s != INVALID_SOCKET {
                BYPASSED.fetch_add(1, Ordering::Relaxed);
                return s;
            }
        }
    }
    real(af, ty, proto, info, group, flags)
}

unsafe extern "system" fn hook_socket(af: i32, ty: i32, proto: i32) -> Socket {
    if let Some(base) = base_provider(af, ty, proto) {
        let real: WsaSocketWFn = std::mem::transmute(REAL_WSASOCKETW.load(Ordering::Relaxed));
        // `socket()` creates overlapped sockets, so ask for the same.
        let s = real(af, ty, proto, base, 0, WSA_FLAG_OVERLAPPED);
        if s != INVALID_SOCKET {
            BYPASSED.fetch_add(1, Ordering::Relaxed);
            return s;
        }
    }
    let real: SocketFn = std::mem::transmute(REAL_SOCKET.load(Ordering::Relaxed));
    real(af, ty, proto)
}

/// One line for the log: how many imports were redirected, which LSPs are installed, and
/// how many sockets were kept off them so far.
pub fn status() -> String {
    let lsps: Vec<String> = catalog()
        .iter()
        .filter(|p| p.protocol_chain.chain_len > BASE_PROTOCOL)
        .map(|p| {
            let end = p.sz_protocol.iter().position(|&c| c == 0).unwrap_or(256);
            String::from_utf16_lossy(&p.sz_protocol[..end])
        })
        .collect();
    format!(
        "LSP bypass: {} import slot(s) redirected, {} socket(s) bypassed, layered providers: {}",
        PATCHED.load(Ordering::SeqCst),
        BYPASSED.load(Ordering::SeqCst),
        if lsps.is_empty() {
            "none".to_owned()
        } else {
            lsps.join("; ")
        }
    )
}
