//! Windows steps. Background first: UI Automation patterns (Invoke, Toggle, Value, Text,
//! Scroll, …) and EM_REPLACESEL for classic edit controls work while the app stays behind.
//! Keys, mouse clicks without a pattern and drags use SendInput with the app briefly in front
//! (handed back) and the user's cursor put back.

use std::time::Duration;

use turbo_core::errors::{ErrorCode, TurboError, TurboResult};
use turbo_core::keys::{Chord, Key, Named};
use turbo_core::platform::{ActCtx, ActTarget, PStep};
use turbo_core::steps::{paste_plain, Button, Caret, Direction};
use windows::Win32::Foundation::{LPARAM, POINT, WPARAM};
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::UI::Controls::{EM_REPLACESEL, EM_SETSEL};
use windows::Win32::UI::WindowsAndMessaging::{GetCursorPos, SendMessageW, SetCursorPos};

use super::uia::El;
use super::Native;

/// dwExtraInfo of every event the helper injects ("CUTB").
pub const TAG: usize = 0x4355_5442;

fn sleep(ms: u64) {
    std::thread::sleep(Duration::from_millis(ms));
}

fn send(inputs: &[INPUT]) {
    unsafe {
        SendInput(inputs, std::mem::size_of::<INPUT>() as i32);
    }
}

fn key_input(vk: VIRTUAL_KEY, scan: u16, flags: KEYBD_EVENT_FLAGS) -> INPUT {
    INPUT { r#type: INPUT_KEYBOARD, Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: vk, wScan: scan, dwFlags: flags, time: 0, dwExtraInfo: TAG } } }
}

fn mouse_input(flags: MOUSE_EVENT_FLAGS, data: i32) -> INPUT {
    INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 { mi: MOUSEINPUT { dx: 0, dy: 0, mouseData: data as u32, dwFlags: flags, time: 0, dwExtraInfo: TAG } },
    }
}

fn tap(vk: VIRTUAL_KEY) {
    send(&[key_input(vk, 0, KEYBD_EVENT_FLAGS(0)), key_input(vk, 0, KEYEVENTF_KEYUP)]);
}

fn type_unicode(ctx: &ActCtx, text: &str) -> TurboResult<usize> {
    let mut n = 0;
    for c in text.chars() {
        if (ctx.interrupted)() {
            return Err(TurboError::new(ErrorCode::HaltedByUser, format!("Typing stopped after {n} character(s).")));
        }
        // Keys go to whatever window is in front: never one that is not the target.
        if !(ctx.still_front)() {
            return Err(TurboError::new(ErrorCode::UserActive, turbo_core::texts::lost_front(&ctx.app.name, n)));
        }
        match c {
            '\n' => tap(VK_RETURN),
            '\t' => tap(VK_TAB),
            _ => {
                let mut buf = [0u16; 2];
                let units = c.encode_utf16(&mut buf);
                let mut ev = vec![];
                for u in units.iter() {
                    ev.push(key_input(VIRTUAL_KEY(0), *u, KEYEVENTF_UNICODE));
                    ev.push(key_input(VIRTUAL_KEY(0), *u, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));
                }
                send(&ev);
            }
        }
        n += 1;
        sleep(6);
    }
    Ok(n)
}

fn vk_of(key: Key) -> Option<(VIRTUAL_KEY, bool)> {
    Some(match key {
        Key::Char(c) => {
            let r = unsafe { VkKeyScanW(c as u16) };
            if r == -1 {
                return None;
            }
            (VIRTUAL_KEY((r & 0xff) as u16), (r >> 8) & 1 == 1)
        }
        Key::Named(n) => (
            match n {
                Named::Return => VK_RETURN,
                Named::Tab => VK_TAB,
                Named::Space => VK_SPACE,
                Named::Escape => VK_ESCAPE,
                Named::Backspace => VK_BACK,
                Named::Delete => VK_DELETE,
                Named::Up => VK_UP,
                Named::Down => VK_DOWN,
                Named::Left => VK_LEFT,
                Named::Right => VK_RIGHT,
                Named::Home => VK_HOME,
                Named::End => VK_END,
                Named::PageUp => VK_PRIOR,
                Named::PageDown => VK_NEXT,
                Named::Insert => VK_INSERT,
                Named::Help => VK_HELP,
                Named::Menu => VK_APPS,
                Named::CapsLock => VK_CAPITAL,
                Named::NumLock => VK_NUMLOCK,
                Named::PrintScreen => VK_SNAPSHOT,
                Named::F(n) => VIRTUAL_KEY(VK_F1.0 + n as u16 - 1),
                Named::KpEnter => VK_RETURN,
                Named::Kp(c) => match c {
                    '0'..='9' => VIRTUAL_KEY(VK_NUMPAD0.0 + (c as u16 - '0' as u16)),
                    '.' => VK_DECIMAL,
                    '+' => VK_ADD,
                    '-' => VK_SUBTRACT,
                    '*' => VK_MULTIPLY,
                    '/' => VK_DIVIDE,
                    _ => VK_RETURN,
                },
                Named::Ctrl => VK_CONTROL,
                Named::Alt => VK_MENU,
                Named::Shift => VK_SHIFT,
                Named::Super => VK_LWIN,
            },
            false,
        ),
    })
}

fn press_chord(chord: &Chord) -> TurboResult<()> {
    let (vk, need_shift) = vk_of(chord.key).ok_or_else(|| TurboError::bad("That key cannot be typed with the current keyboard layout."))?;
    let mut mods = vec![];
    if chord.mods.ctrl {
        mods.push(VK_CONTROL);
    }
    if chord.mods.alt {
        mods.push(VK_MENU);
    }
    if chord.mods.shift || need_shift {
        mods.push(VK_SHIFT);
    }
    if chord.mods.super_ {
        mods.push(VK_LWIN);
    }
    let mut ev: Vec<INPUT> = mods.iter().map(|m| key_input(*m, 0, KEYBD_EVENT_FLAGS(0))).collect();
    ev.push(key_input(vk, 0, KEYBD_EVENT_FLAGS(0)));
    ev.push(key_input(vk, 0, KEYEVENTF_KEYUP));
    ev.extend(mods.iter().rev().map(|m| key_input(*m, 0, KEYEVENTF_KEYUP)));
    send(&ev);
    Ok(())
}

/// Move the real cursor to (x, y), run `f`, put it back.
fn with_cursor(at: (f64, f64), f: impl FnOnce()) {
    let mut original = POINT::default();
    let had = unsafe { GetCursorPos(&mut original).is_ok() };
    unsafe {
        let _ = SetCursorPos(at.0 as i32, at.1 as i32);
    }
    sleep(50);
    f();
    sleep(120);
    if had {
        unsafe {
            let _ = SetCursorPos(original.x, original.y);
        }
    }
}

fn mouse_click(ctx: &ActCtx, at: (f64, f64), button: Button, times: u8) -> TurboResult<String> {
    (ctx.borrow_front)("clicking")?;
    let (down, up) = match button {
        Button::Left => (MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP),
        Button::Right => (MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP),
        Button::Middle => (MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP),
    };
    with_cursor(at, || {
        for _ in 0..times.max(1) {
            send(&[mouse_input(down, 0)]);
            sleep(30);
            send(&[mouse_input(up, 0)]);
            sleep(60);
        }
    });
    ctx.note(turbo_core::texts::real_pointer_note(&ctx.app.name));
    Ok(format!("Clicked at screen point ({}, {}).", at.0 as i64, at.1 as i64))
}

fn is_edit_control(class: &str) -> bool {
    let c = class.to_lowercase();
    c == "edit" || c.starts_with("richedit")
}

/// Insert at the caret of a classic edit control (works in the background).
fn replace_sel(el: &El, text: &str) -> bool {
    let Some(h) = el.hwnd() else { return false };
    let wide: Vec<u16> = text.replace('\n', "\r\n").encode_utf16().chain(Some(0)).collect();
    unsafe {
        SendMessageW(h, EM_REPLACESEL, WPARAM(1), LPARAM(wide.as_ptr() as isize));
    }
    true
}

fn refuse_if_password_focused(native: &Native) -> TurboResult<()> {
    if native.uia.focused().is_some_and(|f| f.is_password()) {
        return Err(TurboError::new(ErrorCode::PasswordGuard, "The focused element is a password field. Computer Use never types into password fields; ask the user to enter it."));
    }
    Ok(())
}

fn write_text(native: &Native, ctx: &ActCtx, text: &str, el: Option<El>) -> TurboResult<String> {
    let total = text.chars().count();
    let target = el.clone().or_else(|| native.uia.focused().filter(|f| f.pid() == Some(ctx.pid)));
    if let Some(t) = &target {
        if is_edit_control(&t.class()) && replace_sel(t, text) {
            return Ok(format!("Typed {total} character(s) (inserted in the background)."));
        }
        if el.is_some() && !text.contains(['\n', '\t']) && t.value_writable() && t.value().unwrap_or_default().is_empty() && t.set_value(text) {
            return Ok(format!("Typed {total} character(s) (set through accessibility)."));
        }
    }
    (ctx.borrow_front)("typing")?;
    if let Some(t) = &el {
        t.focus();
        sleep(60);
    }
    refuse_if_password_focused(native)?;
    let n = type_unicode(ctx, text)?;
    // Key presses become text only in something that takes text.
    let focus = native.uia.focused();
    if !focus.as_ref().is_some_and(|f| f.accepts_text()) {
        let what = focus.as_ref().map(|f| f.describe()).unwrap_or_else(|| "no element (nothing has the keyboard focus)".into());
        return Ok(turbo_core::texts::keys_to_non_text(n, &what, &ctx.app.name));
    }
    Ok(format!("Typed {n} character(s) (as key events)."))
}

pub fn act(native: &Native, ctx: &ActCtx, step: PStep<El>) -> TurboResult<Option<String>> {
    let note = match step {
        PStep::Click { target, button, times } => match target {
            ActTarget::Element { index, el } => {
                if button == Button::Left && times == 1 && !ctx.self_drawn {
                    if el.invoke() {
                        return Ok(Some(format!("Pressed #{index} with its accessibility action.")));
                    }
                    if el.toggle() {
                        return Ok(Some(format!("Toggled #{index}.")));
                    }
                    if el.select() {
                        return Ok(Some(format!("Selected #{index}.")));
                    }
                    if let Some(open) = el.expanded() {
                        if el.expand(!open) {
                            return Ok(Some(format!("{} #{index}.", if open { "Collapsed" } else { "Expanded" })));
                        }
                    }
                }
                el.scroll_into_view();
                let at = el.center().ok_or_else(|| TurboError::action(format!("Element #{index} has no on-screen position; scroll it into view or observe again.")))?;
                mouse_click(ctx, at, button, times)?
            }
            ActTarget::Point { x, y } => mouse_click(ctx, (x, y), button, times)?,
        },
        PStep::Scroll { target, direction, pages } => {
            let (vertical, forward) = match direction {
                Direction::Up => (true, false),
                Direction::Down => (true, true),
                Direction::Left => (false, false),
                Direction::Right => (false, true),
            };
            let n = pages.ceil().max(1.0) as u32;
            let at = match &target {
                ActTarget::Element { el, .. } => {
                    if el.scroll(vertical, forward, n) {
                        return Ok(Some(format!("Scrolled {} {pages} page(s) through accessibility.", format!("{direction:?}").to_lowercase())));
                    }
                    el.center()
                }
                ActTarget::Point { x, y } => Some((*x, *y)),
            }
            .ok_or_else(|| TurboError::action("Nothing to scroll there."))?;
            (ctx.borrow_front)("scrolling")?;
            let notches = ((pages * 5.0).round() as i32).max(1);
            with_cursor(at, || {
                for _ in 0..notches {
                    let delta = if forward { -120 } else { 120 };
                    send(&[mouse_input(if vertical { MOUSEEVENTF_WHEEL } else { MOUSEEVENTF_HWHEEL }, if vertical { delta } else { -delta })]);
                    sleep(15);
                }
            });
            ctx.note(turbo_core::texts::real_pointer_note(&ctx.app.name));
            format!("Scrolled {} {pages} page(s).", format!("{direction:?}").to_lowercase())
        }
        PStep::Drag { from, to } => {
            (ctx.borrow_front)("dragging")?;
            let mut original = POINT::default();
            let had = unsafe { GetCursorPos(&mut original).is_ok() };
            unsafe {
                let _ = SetCursorPos(from.0 as i32, from.1 as i32);
            }
            sleep(80);
            send(&[mouse_input(MOUSEEVENTF_LEFTDOWN, 0)]);
            sleep(120);
            for i in 1..=16 {
                if (ctx.interrupted)() {
                    unsafe {
                        let _ = SetCursorPos(from.0 as i32, from.1 as i32);
                    }
                    send(&[mouse_input(MOUSEEVENTF_LEFTUP, 0)]);
                    return Err(TurboError::halted());
                }
                let t = i as f64 / 16.0;
                unsafe {
                    let _ = SetCursorPos((from.0 + (to.0 - from.0) * t) as i32, (from.1 + (to.1 - from.1) * t) as i32);
                }
                send(&[mouse_input(MOUSEEVENTF_MOVE, 0)]);
                sleep(25);
            }
            sleep(200);
            send(&[mouse_input(MOUSEEVENTF_LEFTUP, 0)]);
            sleep(150);
            if had {
                unsafe {
                    let _ = SetCursorPos(original.x, original.y);
                }
            }
            ctx.note(turbo_core::texts::real_pointer_note(&ctx.app.name));
            "Dragged.".into()
        }
        PStep::WriteText { text, el } => write_text(native, ctx, &text, el)?,
        PStep::SendKeys { chord, shown } => {
            (ctx.borrow_front)(&format!("the key press \"{shown}\""))?;
            refuse_if_password_focused(native)?;
            if !(ctx.still_front)() {
                return Err(TurboError::new(ErrorCode::UserActive, turbo_core::texts::lost_front(&ctx.app.name, 0)));
            }
            press_chord(&chord)?;
            format!("Pressed {shown}.")
        }
        PStep::FillValue { el, value } => {
            let v = value.trim();
            let ok = if let Ok(n) = v.parse::<f64>().map_err(|_| ()).and_then(|n| if el.pattern::<windows::Win32::UI::Accessibility::IUIAutomationRangeValuePattern>(windows::Win32::UI::Accessibility::UIA_RangeValuePatternId).is_some() { Ok(n) } else { Err(()) }) {
                el.set_range(n)
            } else if el.value_writable() {
                el.set_value(&value)
            } else if let Some(want) = match v.to_lowercase().as_str() {
                "1" | "true" | "yes" | "on" | "checked" | "selected" => Some(true),
                "0" | "false" | "no" | "off" | "unchecked" | "unselected" => Some(false),
                _ => None,
            } {
                el.toggle_state() == Some(want) || el.toggle()
            } else {
                return Err(TurboError::new(ErrorCode::NotSupported, "The value of this element is not settable; try click_at + write_text instead."));
            };
            if !ok {
                return Err(TurboError::action("Setting the value failed."));
            }
            sleep(150);
            let now = el.value().unwrap_or_default();
            if el.value_writable() && now.trim() != value.trim() {
                format!("The value was set, but the element now reads \"{}\" (the app may have reverted or reformatted it).", turbo_core::protocol::clean(&now, 80))
            } else {
                return Ok(None);
            }
        }
        PStep::PickText { el, start, len, mode } => {
            let caret = match mode {
                Caret::Select => None,
                Caret::Before => Some(false),
                Caret::After => Some(true),
            };
            if el.select_text(start, len, caret) {
                return Ok(None);
            }
            if is_edit_control(&el.class()) {
                if let Some(h) = el.hwnd() {
                    let (s, e) = match caret {
                        None => (start, start + len),
                        Some(false) => (start, start),
                        Some(true) => (start + len, start + len),
                    };
                    unsafe {
                        SendMessageW(h, EM_SETSEL, WPARAM(s), LPARAM(e as isize));
                    }
                    return Ok(None);
                }
            }
            return Err(TurboError::action("Selecting the text through accessibility failed."));
        }
        PStep::InvokeAction { el, name } => {
            let want: String = name.to_lowercase().chars().filter(|c| c.is_alphanumeric()).collect();
            let ok = match want.as_str() {
                "press" | "invoke" => el.invoke(),
                "toggle" => el.toggle(),
                "expand" => el.expand(true),
                "collapse" => el.expand(false),
                "select" => el.select(),
                "scrollup" => el.scroll(true, false, 1),
                "scrolldown" => el.scroll(true, true, 1),
                "increment" => el.step_range(true),
                "decrement" => el.step_range(false),
                "raise" => {
                    (ctx.borrow_front)("switching to that window")?;
                    true
                }
                _ => return Err(TurboError::new(ErrorCode::NotSupported, format!("Action \"{}\" is not available on this element.", turbo_core::protocol::clean(&name, 60)))),
            };
            if !ok {
                return Err(TurboError::action(format!("Performing {name} failed.")));
            }
            return Ok(None);
        }
        PStep::PasteText { text, format } => {
            let plain = paste_plain(&text, format);
            let n = write_text(native, ctx, &plain, None)?;
            if format == turbo_core::steps::PasteFormat::Text {
                n
            } else {
                format!("{n} Rich formatting is inserted as plain text on Windows; your clipboard was not used.")
            }
        }
        PStep::RunCommand { path } => native.run_command(ctx.app, &path)?,
    };
    Ok(Some(note))
}
