//! Team edition: system-wide "Force close all" hotkey (the Pause/Break key).
//!
//! Registered with Windows `RegisterHotKey`, so it fires whichever app is
//! active. It cannot fire on the Windows lock screen: that is a separate
//! secure desktop no normal app receives keys on. The main window handles the
//! `force_close_all` event by closing every session window and hiding itself.
//!
//! While a remote session window has focus, RustDesk's keyboard grab swallows
//! keys before Windows can turn them into a hotkey, so the grab calls
//! [`trigger`] itself for Pause (see `start_grab_loop` in `keyboard.rs`).

use hbb_common::log;
use std::sync::Once;
use winapi::um::winuser::{GetMessageW, RegisterHotKey, MOD_NOREPEAT, MSG, VK_PAUSE, WM_HOTKEY};

const HOTKEY_ID: i32 = 0x5443; // any id unique within this process

pub fn start() {
    static START: Once = Once::new();
    START.call_once(|| {
        std::thread::spawn(|| unsafe {
            // Pause alone, no modifiers. MOD_NOREPEAT: holding the key fires once.
            let mods = MOD_NOREPEAT as u32;
            if RegisterHotKey(std::ptr::null_mut(), HOTKEY_ID, mods, VK_PAUSE as u32) == 0 {
                log::warn!("Force close all hotkey not registered (used by another app?)");
                return;
            }
            log::info!("Force close all hotkey registered: Pause");
            let mut msg: MSG = std::mem::zeroed();
            while GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0) > 0 {
                if msg.message == WM_HOTKEY && msg.wParam as i32 == HOTKEY_ID {
                    trigger();
                }
            }
        });
    });
}

/// Ask the main window to force close all session windows and hide itself.
pub fn trigger() {
    let _ = crate::flutter::push_global_event(
        crate::flutter::APP_TYPE_MAIN,
        r#"{"name":"force_close_all"}"#.to_owned(),
    );
}
