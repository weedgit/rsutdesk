# Team Edition (LAN only)

An internal, not-for-sale build of RustDesk for one team on one local network.

- **Desktop app only:** Windows, Ubuntu and macOS, with the Flutter UI.
- **Local network only:** it never contacts an ID, relay, API, account or update server.
- **No passwords:** each desktop keeps an **allowed IP list**. Only those IPs can connect.
- **Full remote control:** screen, keyboard, mouse, text and file copy/paste, file transfer.

The switch is `LAN_ONLY` in [libs/base/src/team.rs](libs/base/src/team.rs), and `kTeamLanOnly` in
[flutter/lib/consts.dart](flutter/lib/consts.dart) must match it.

## How it works

| | Stock RustDesk | Team edition |
|---|---|---|
| Finding a desktop | ID via the public/self-hosted ID server | IP, hostname, or ID from the **Local network** tab (LAN discovery) |
| Connection | Hole punching or relay | Direct TCP to `IP:21118` |
| Who may connect | Password / click to accept | IP in the desktop's **allowed IP list**, nothing else |
| Accounts, address book, groups | API server | Removed. Use **Recent**, **Favorites** and **Local network** |
| Updates | Checks rustdesk.com | Disabled |

An empty allowed IP list lets **nobody** connect. This is on purpose: a new install is closed
until someone opens it.

## Network ports (open them on each desktop's firewall, LAN only)

| Port | Protocol | Purpose |
|---|---|---|
| 21118 | TCP | Remote sessions (direct access) |
| 21119 | UDP | LAN discovery (the Local network tab) |

## Setting up a desktop

1. Install the app, and choose **Install** (Windows) so it runs as a service. Only then can
   you control UAC prompts and the login screen.
2. Open **Settings > Security > Allowed IPs**, or click the pencil next to **Allowed IPs**
   on the home screen. Add the controlling machines' IPs, one per line:
   - one machine: `192.168.1.20`
   - a whole subnet: `192.168.1.0/24`
   - everyone (testing only): `*`
3. The home screen shows **this machine's IP**. Teammates add it to their own lists if they
   need to control this one.

### Scripted setup (many desktops)

On an installed desktop, from an elevated shell:

```bash
rustdesk --option whitelist "192.168.1.0/24,10.0.5.12"
```

To read the current list:

```bash
rustdesk --option whitelist
```

On Windows the binary is `"C:\Program Files\RustDesk\rustdesk.exe"`.

## Connecting

Type one of these in **Control Remote Desktop**:

- an IP address: `192.168.1.20`
- a hostname: `office-pc` or `office-pc.local`
- an ID listed in the **Local network** tab

Star a desktop to keep it in **Favorites**, and rename it from its card's menu.

## Per-OS notes

- **Windows:** install it as a service (step 1) to control elevated windows and the login screen.
- **Windows with a VPN/proxy (Astrill etc.):** works. Some VPNs install an old Winsock "LSP"
  that crashes apps using modern async sockets. Astrill's `ASProxy64.dll` does, and it also
  crashes Cursor and VS Code. RustDesk now creates its sockets on Windows' base provider, so
  no LSP is in their path. See [src/platform/windows_lsp_bypass.rs](src/platform/windows_lsp_bypass.rs).
  The log line `LSP bypass: ...` shows which LSPs were skipped. Side effect: RustDesk's own
  traffic does not go through such a proxy, which is what you want on a LAN.
- **macOS:** grant **Screen Recording** and **Accessibility** in System Settings > Privacy &
  Security. Unsigned builds may lose these grants after each rebuild. Signing with an Apple
  Developer ID avoids that.
- **Ubuntu:** an **X11** session works best. On Wayland, screen capture goes through a portal
  that asks for permission each time, so unattended access is limited. Choose "Ubuntu on Xorg"
  at login, or build with the `drm` feature.
- **File copy/paste:** works on all three. Linux and macOS need the `unix-file-copy-paste`
  feature, which `build.py --flutter --unix-file-copy-paste` turns on.

## Building

Only the Flutter UI is supported. A build without it stops with a clear error.

Prerequisites: Rust, [vcpkg](https://github.com/microsoft/vcpkg) with `VCPKG_ROOT` set (libvpx,
libyuv, opus, aom), the Flutter SDK and `flutter_rust_bridge_codegen`. See the upstream
[build docs](https://rustdesk.com/docs/en/dev/build/).

```bash
python3 build.py --flutter --hwcodec --unix-file-copy-paste
```

Run the policy unit tests (no vcpkg needed):

```bash
cargo test -p base team
```

## What was removed

- Android and iOS projects and build scripts, plus the F-Droid metadata (`fastlane/`).
- The account, address book and device-group panels, the ID/relay/proxy/WebSocket settings,
  password and 2FA settings, the "request approval" menu and the update check. The code stays
  where removing it would mean large rewrites, but it is switched off at the entry points.
  Search for `LAN_ONLY` / `kTeamLanOnly` to find each switch.

## License

RustDesk is AGPL-3.0. Internal team use is fine. If you ever give the app to anyone outside
the team, you must also offer them this source code.
