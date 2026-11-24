//! Team edition: system-wide hotkeys on Windows (`RegisterHotKey`).
//!
//! - Shift + Home: bring remote session windows to the foreground (stealth UI has no tray).
//! - Ctrl + Shift + Home: bring the main window to the foreground.
//! - Pause/Break (unchanged): force close all sessions and hide the main window.
//!
//! While a remote session has the keyboard grab, Windows may not deliver hotkeys; the grab
//! loop in `keyboard.rs` calls the same triggers for Pause and Home with modifiers.

use hbb_common::log;
use std::sync::Once;
use winapi::um::winuser::{
    GetMessageW, RegisterHotKey, MOD_CONTROL, MOD_NOREPEAT, MOD_SHIFT, MSG, VK_HOME, VK_PAUSE,
    WM_HOTKEY,
};

const HOTKEY_FORCE_CLOSE_ALL: i32 = 0x5443;
const HOTKEY_BRING_REMOTE: i32 = 0x5444;
const HOTKEY_BRING_MAIN: i32 = 0x5445;

pub fn start() {
    static START: Once = Once::new();
    START.call_once(|| {
        std::thread::spawn(|| unsafe {
            let mut registered = 0;
            if RegisterHotKey(
                std::ptr::null_mut(),
                HOTKEY_FORCE_CLOSE_ALL,
                MOD_NOREPEAT as u32,
                VK_PAUSE as u32,
            ) != 0
            {
                registered += 1;
                log::info!("Team hotkey: Pause → force close all");
            } else {
                log::warn!("Team hotkey: Pause not registered (used by another app?)");
            }
            if RegisterHotKey(
                std::ptr::null_mut(),
                HOTKEY_BRING_REMOTE,
                MOD_NOREPEAT as u32 | MOD_SHIFT as u32,
                VK_HOME as u32,
            ) != 0
            {
                registered += 1;
                log::info!("Team hotkey: Shift+Home → bring remote windows forward");
            } else {
                log::warn!("Team hotkey: Shift+Home not registered");
            }
            if RegisterHotKey(
                std::ptr::null_mut(),
                HOTKEY_BRING_MAIN,
                MOD_NOREPEAT as u32 | MOD_SHIFT as u32 | MOD_CONTROL as u32,
                VK_HOME as u32,
            ) != 0
            {
                registered += 1;
                log::info!("Team hotkey: Ctrl+Shift+Home → bring main window forward");
            } else {
                log::warn!("Team hotkey: Ctrl+Shift+Home not registered");
            }
            if registered == 0 {
                return;
            }
            let mut msg: MSG = std::mem::zeroed();
            while GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0) > 0 {
                if msg.message != WM_HOTKEY {
                    continue;
                }
                match msg.wParam as i32 {
                    HOTKEY_FORCE_CLOSE_ALL => trigger_force_close_all(),
                    HOTKEY_BRING_REMOTE => trigger_bring_remote_front(),
                    HOTKEY_BRING_MAIN => trigger_bring_main_front(),
                    _ => {}
                }
            }
        });
    });
}

pub fn trigger_force_close_all() {
    let _ = crate::flutter::push_global_event(
        crate::flutter::APP_TYPE_MAIN,
        r#"{"name":"force_close_all"}"#.to_owned(),
    );
}

pub fn trigger_bring_remote_front() {
    let _ = crate::flutter::push_global_event(
        crate::flutter::APP_TYPE_MAIN,
        r#"{"name":"bring_remote_front"}"#.to_owned(),
    );
}

pub fn trigger_bring_main_front() {
    let _ = crate::flutter::push_global_event(
        crate::flutter::APP_TYPE_MAIN,
        r#"{"name":"bring_main_front"}"#.to_owned(),
    );
}

/// Backwards-compatible name for the keyboard grab.
pub fn trigger() {
    trigger_force_close_all();
}
