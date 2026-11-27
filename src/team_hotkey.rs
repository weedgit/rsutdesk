//! Team edition: system-wide hotkeys.
//!
//! - **Pause/Break**: Force close all session windows and hide the main window.
//! - **Shift+ScrollLock**: Toggle minimize / restore all windows.
//!
//! Registered with Windows `RegisterHotKey`, so they fire whichever app is
//! active. They cannot fire on the Windows lock screen: that is a separate
//! secure desktop no normal app receives keys on.
//!
//! While a remote session window has focus, RustDesk's keyboard grab swallows
//! keys before Windows can turn them into a hotkey, so the grab calls
//! [`trigger`] / [`trigger_toggle_minimize`] itself (see `start_grab_loop` in
//! `keyboard.rs`).

use hbb_common::log;
use std::sync::Once;
use winapi::um::winuser::{
    GetMessageW, RegisterHotKey, MOD_NOREPEAT, MOD_SHIFT, MSG, VK_PAUSE, VK_SCROLL, WM_HOTKEY,
};

const HOTKEY_FORCE_CLOSE: i32 = 0x5443;
const HOTKEY_TOGGLE_MINIMIZE: i32 = 0x5444;

pub fn start() {
    static START: Once = Once::new();
    START.call_once(|| {
        std::thread::spawn(|| unsafe {
            let norepeat = MOD_NOREPEAT as u32;

            if RegisterHotKey(
                std::ptr::null_mut(),
                HOTKEY_FORCE_CLOSE,
                norepeat,
                VK_PAUSE as u32,
            ) == 0
            {
                log::warn!("Force close all hotkey not registered (used by another app?)");
            } else {
                log::info!("Force close all hotkey registered: Pause");
            }

            if RegisterHotKey(
                std::ptr::null_mut(),
                HOTKEY_TOGGLE_MINIMIZE,
                norepeat | MOD_SHIFT as u32,
                VK_SCROLL as u32,
            ) == 0
            {
                log::warn!("Toggle minimize hotkey not registered (used by another app?)");
            } else {
                log::info!("Toggle minimize hotkey registered: Shift+ScrollLock");
            }

            let mut msg: MSG = std::mem::zeroed();
            while GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0) > 0 {
                if msg.message == WM_HOTKEY {
                    match msg.wParam as i32 {
                        HOTKEY_FORCE_CLOSE => trigger(),
                        HOTKEY_TOGGLE_MINIMIZE => trigger_toggle_minimize(),
                        _ => {}
                    }
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

/// Ask the main window to toggle minimize / restore all windows.
pub fn trigger_toggle_minimize() {
    let _ = crate::flutter::push_global_event(
        crate::flutter::APP_TYPE_MAIN,
        r#"{"name":"toggle_minimize"}"#.to_owned(),
    );
}
