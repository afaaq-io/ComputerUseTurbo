//! Menu commands of classic Windows apps: the window's menu
//! (HMENU) is read with the menu API, without opening it, and a command is run by posting its
//! WM_COMMAND to the window — in the background. Apps with menus of their own drawing (ribbons,
//! many modern apps) have no such menu: they list no commands.

use std::time::Instant;

use turbo_core::events::{self, Command, Located, MenuRead};
use windows::core::PWSTR;
use windows::Win32::Foundation::{HWND, LPARAM, WPARAM};
use windows::Win32::UI::WindowsAndMessaging::{
    GetMenu, GetMenuItemCount, GetMenuItemInfoW, PostMessageW, SendMessageTimeoutW, HMENU, MENUITEMINFOW, MFS_DISABLED, MFT_SEPARATOR,
    MIIM_FTYPE, MIIM_ID, MIIM_STATE, MIIM_STRING, MIIM_SUBMENU, SMTO_ABORTIFHUNG, WM_COMMAND, WM_INITMENUPOPUP,
};

const MAX_ITEMS: usize = 4000;
const MAX_DEPTH: usize = 6;

struct Item {
    raw: String,
    id: u32,
    disabled: bool,
    sub: Option<HMENU>,
}

fn items(menu: HMENU) -> Vec<Item> {
    let n = unsafe { GetMenuItemCount(menu) };
    let mut out = vec![];
    for i in 0..n.max(0) as u32 {
        let mut info = MENUITEMINFOW {
            cbSize: std::mem::size_of::<MENUITEMINFOW>() as u32,
            fMask: MIIM_FTYPE | MIIM_ID | MIIM_STATE | MIIM_SUBMENU | MIIM_STRING,
            ..Default::default()
        };
        if unsafe { GetMenuItemInfoW(menu, i, true, &mut info) }.is_err() {
            continue;
        }
        if info.fType.0 & MFT_SEPARATOR.0 != 0 {
            continue;
        }
        let mut buf = vec![0u16; info.cch as usize + 1];
        info.dwTypeData = PWSTR(buf.as_mut_ptr());
        info.cch += 1;
        let raw = if unsafe { GetMenuItemInfoW(menu, i, true, &mut info) }.is_ok() {
            String::from_utf16_lossy(&buf[..(info.cch as usize).min(buf.len())])
        } else {
            String::new()
        };
        let sub = (!info.hSubMenu.is_invalid()).then_some(info.hSubMenu);
        out.push(Item { raw, id: info.wID, disabled: info.fState.0 & MFS_DISABLED.0 != 0, sub });
    }
    out
}

/// Let the app bring a submenu up to date (enabled states, dynamic items), as it does
/// right before showing it.
fn refresh(window: HWND, sub: HMENU, index: usize) {
    unsafe {
        let _ = SendMessageTimeoutW(window, WM_INITMENUPOPUP, WPARAM(sub.0 as usize), LPARAM(index as isize), SMTO_ABORTIFHUNG, 200, None);
    }
}

pub fn read(window: HWND, deadline: Instant) -> MenuRead {
    let mut out = MenuRead::default();
    let bar = unsafe { GetMenu(window) };
    if bar.is_invalid() {
        return out;
    }
    fn walk(window: HWND, menu: HMENU, path: &[String], depth: usize, deadline: Instant, out: &mut MenuRead) {
        if depth > MAX_DEPTH {
            return;
        }
        for (i, it) in items(menu).into_iter().enumerate() {
            if out.commands.len() >= MAX_ITEMS || Instant::now() > deadline {
                out.truncated = true;
                return;
            }
            let title = events::display_title(&it.raw);
            if title.trim().is_empty() || events::looks_app_filled(&it.raw) {
                continue;
            }
            let mut p = path.to_vec();
            p.push(title);
            match it.sub {
                Some(sub) => {
                    refresh(window, sub, i);
                    walk(window, sub, &p, depth + 1, deadline, out);
                }
                None => {
                    let shortcut = it.raw.split_once('\t').and_then(|(_, k)| events::shortcut_text(k));
                    out.commands.push(Command { path: p, shortcut, enabled: Some(!it.disabled) });
                }
            }
        }
    }
    walk(window, bar, &[], 1, deadline, &mut out);
    out
}

pub fn signature(window: HWND, exe: &str) -> String {
    let mut parts = vec![std::fs::metadata(exe).and_then(|m| m.modified()).map(|t| format!("{t:?}")).unwrap_or_default()];
    let bar = unsafe { GetMenu(window) };
    if !bar.is_invalid() {
        for it in items(bar) {
            parts.push(format!("{}#{}", events::display_title(&it.raw), it.sub.map(|s| unsafe { GetMenuItemCount(s) }).unwrap_or(0)));
        }
    }
    parts.join("|")
}

/// The command at `path`: its id and state.
pub fn locate(window: HWND, path: &[String]) -> Option<(u32, Located)> {
    let mut menu = unsafe { GetMenu(window) };
    if menu.is_invalid() {
        return None;
    }
    let mut actual = vec![];
    for (depth, wanted) in path.iter().enumerate() {
        let list = items(menu);
        let (i, it) = list.into_iter().enumerate().find(|(_, it)| events::same_title(&it.raw, wanted))?;
        actual.push(events::display_title(&it.raw));
        let last = depth == path.len() - 1;
        match (it.sub, last) {
            (Some(sub), false) => {
                refresh(window, sub, i);
                menu = sub;
            }
            (sub, true) => return Some((it.id, Located { path: actual, enabled: !it.disabled, has_submenu: sub.is_some() })),
            (None, false) => return None,
        }
    }
    None
}

/// Run a command the way choosing it in the menu does.
pub fn run(window: HWND, id: u32) -> bool {
    unsafe { PostMessageW(window, WM_COMMAND, WPARAM(id as usize & 0xFFFF), LPARAM(0)).is_ok() }
}
