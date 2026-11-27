//! Team edition: system-wide hotkeys.
//!
//! - **Pause/Break**: Force close all session windows and hide the main window.
//! - **Shift+ScrollLock**: Toggle minimize / restore all windows.
//! - **Shift+Home**: Decrease remote window opacity by 10%.
//! - **Shift+End**: Increase remote window opacity by 10%.
//!
//! Registered with Windows `RegisterHotKey`, so they fire whichever app is
//! active. They cannot fire on the Windows lock screen: that is a separate
//! secure desktop no normal app receives keys on.
//!
//! While a remote session window has focus, RustDesk's keyboard grab swallows
//! keys before Windows can turn them into a hotkey, so the grab calls
//! the corresponding trigger function itself (see `start_grab_loop` in
//! `keyboard.rs`).

use hbb_common::log;
use std::sync::Once;
use winapi::um::winuser::{
    GetMessageW, RegisterHotKey, MOD_NOREPEAT, MOD_SHIFT, MSG, VK_END, VK_HOME, VK_PAUSE,
    VK_SCROLL, WM_HOTKEY,
};

const HOTKEY_FORCE_CLOSE: i32 = 0x5443;
const HOTKEY_TOGGLE_MINIMIZE: i32 = 0x5444;
const HOTKEY_OPACITY_DOWN: i32 = 0x5445;
const HOTKEY_OPACITY_UP: i32 = 0x5446;

pub fn start() {
    static START: Once = Once::new();
    START.call_once(|| {
        std::thread::spawn(|| unsafe {
            let norepeat = MOD_NOREPEAT as u32;
            let shift = norepeat | MOD_SHIFT as u32;

            let hotkeys: &[(i32, u32, u32, &str)] = &[
                (HOTKEY_FORCE_CLOSE, norepeat, VK_PAUSE as u32, "Pause"),
                (HOTKEY_TOGGLE_MINIMIZE, shift, VK_SCROLL as u32, "Shift+ScrollLock"),
                (HOTKEY_OPACITY_DOWN, shift, VK_HOME as u32, "Shift+Home"),
                (HOTKEY_OPACITY_UP, shift, VK_END as u32, "Shift+End"),
            ];
            for &(id, mods, vk, label) in hotkeys {
                if RegisterHotKey(std::ptr::null_mut(), id, mods, vk) == 0 {
                    log::warn!("{label} hotkey not registered (used by another app?)");
                } else {
                    log::info!("{label} hotkey registered");
                }
            }

            let mut msg: MSG = std::mem::zeroed();
            while GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0) > 0 {
                if msg.message == WM_HOTKEY {
                    match msg.wParam as i32 {
                        HOTKEY_FORCE_CLOSE => trigger_force_close(),
                        HOTKEY_TOGGLE_MINIMIZE => trigger_toggle_minimize(),
                        HOTKEY_OPACITY_DOWN => trigger_opacity_down(),
                        HOTKEY_OPACITY_UP => trigger_opacity_up(),
                        _ => {}
                    }
                }
            }
        });
    });
}

pub fn trigger_force_close() {
    let _ = crate::flutter::push_global_event(
        crate::flutter::APP_TYPE_MAIN,
        r#"{"name":"force_close_all"}"#.to_owned(),
    );
}

pub fn trigger_toggle_minimize() {
    let _ = crate::flutter::push_global_event(
        crate::flutter::APP_TYPE_MAIN,
        r#"{"name":"toggle_minimize"}"#.to_owned(),
    );
}

pub fn trigger_opacity_down() {
    let _ = crate::flutter::push_global_event(
        crate::flutter::APP_TYPE_MAIN,
        r#"{"name":"opacity_down"}"#.to_owned(),
    );
}

pub fn trigger_opacity_up() {
    let _ = crate::flutter::push_global_event(
        crate::flutter::APP_TYPE_MAIN,
        r#"{"name":"opacity_up"}"#.to_owned(),
    );
}
