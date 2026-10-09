//! Linux steps. Background first: AT-SPI actions, text insertion, values and selections work
//! while the app stays behind. Only what has no accessibility path (shortcuts, mouse clicks
//! on things without an action, drags, apps that ignore text insertion) uses real input:
//! XTest for X11 windows (the app briefly in front, the user's pointer put back), the shared
//! window's EIS devices for Wayland windows (the window must be in front: Wayland delivers
//! input to what is on top, and no app may raise another's window).

use std::sync::Arc;
use std::time::Duration;

use turbo_core::errors::{ErrorCode, TurboError, TurboResult};
use turbo_core::keys::{Chord, Key, Named};
use turbo_core::platform::{ActCtx, ActTarget, PStep};
use turbo_core::steps::{paste_plain, Button, Caret, Direction};

use super::atspi::{has, state, Atspi, El};
use super::eis::{self, Eis};
use super::x11::{keysym_for_char, X11};
use super::Native;

fn sleep(ms: u64) {
    std::thread::sleep(Duration::from_millis(ms));
}

/// Where real input goes: XTest, or the shared screen's devices (Wayland; positions are
/// desktop coordinates, which the devices' regions use directly).
enum Real<'a> {
    X(&'a X11),
    W(Arc<Eis>),
}

fn real<'a>(native: &'a Native, ctx: &ActCtx) -> TurboResult<Real<'a>> {
    if native.native_wayland(ctx.pid) {
        let name = &ctx.app.name;
        let link = native.link().ok_or_else(|| {
            TurboError::new(
                ErrorCode::NotSupported,
                format!("The screen is not shared, so clicks at x/y and key presses cannot reach {name} (Wayland). Call observe_app: the user is asked once to share the screen. Element numbers with accessibility actions work without it."),
            )
        })?;
        let input = link.input().cloned().ok_or_else(|| {
            TurboError::new(
                ErrorCode::NotSupported,
                format!("The screen is shared without remote interaction, so clicks at x/y and key presses cannot reach {name}. Element numbers with accessibility actions still work."),
            )
        })?;
        return Ok(Real::W(input));
    }
    native.x11.as_ref().map(Real::X).ok_or_else(|| TurboError::new(ErrorCode::NotSupported, "This step needs an X11 display (real input), which is not available."))
}

fn x(native: &Native) -> TurboResult<&X11> {
    native.x11.as_ref().ok_or_else(|| TurboError::new(ErrorCode::NotSupported, "This step needs an X11 display (real input), which is not available."))
}

fn editable(a: &Atspi, el: &El) -> bool {
    a.interfaces(el).iter().any(|i| i.ends_with("EditableText"))
}

fn norm(s: &str) -> String {
    s.to_lowercase().chars().filter(|c| c.is_alphanumeric()).collect::<String>().trim_start_matches("ax").to_string()
}

fn action_index(a: &Atspi, el: &El, wanted: &[&str]) -> Option<i32> {
    let names = a.actions(el);
    for w in wanted {
        if let Some(i) = names.iter().position(|n| n.eq_ignore_ascii_case(w)) {
            return Some(i as i32);
        }
    }
    None
}

/// Move the real pointer to (x, y), run `f`, put the pointer back.
fn with_pointer(xs: &X11, at: (f64, f64), f: impl FnOnce(&X11)) {
    let original = xs.pointer();
    xs.motion(at.0 as i16, at.1 as i16);
    sleep(60);
    f(xs);
    sleep(120);
    if let Some((ox, oy)) = original {
        xs.warp(ox, oy);
    }
}

fn mouse_click(native: &Native, ctx: &ActCtx, at: (f64, f64), button: Button, times: u8) -> TurboResult<String> {
    let r = real(native, ctx)?;
    (ctx.borrow_front)("clicking")?;
    if let Real::W(input) = &r {
        let code = match button {
            Button::Left => eis::BTN_LEFT,
            Button::Middle => eis::BTN_MIDDLE,
            Button::Right => eis::BTN_RIGHT,
        };
        if !input.click(None, at.0, at.1, code, times) {
            return Err(TurboError::action("The shared window offers no pointer for clicking right now; observe again."));
        }
        return Ok(format!("Clicked at ({}, {}).", at.0 as i64, at.1 as i64));
    }
    let Real::X(xs) = r else { unreachable!() };
    let b = match button {
        Button::Left => 1,
        Button::Middle => 2,
        Button::Right => 3,
    };
    with_pointer(xs, at, |xs| {
        for _ in 0..times.max(1) {
            xs.button(b, true);
            sleep(30);
            xs.button(b, false);
            sleep(60);
        }
    });
    ctx.note(turbo_core::texts::real_pointer_note(&ctx.app.name));
    Ok(format!("Clicked at screen point ({}, {}).", at.0 as i64, at.1 as i64))
}

fn keysym_of(key: Key) -> u32 {
    match key {
        Key::Char(c) => keysym_for_char(c.to_ascii_lowercase()),
        Key::Named(n) => match n {
            Named::Return => 0xff0d,
            Named::Tab => 0xff09,
            Named::Space => 0x20,
            Named::Escape => 0xff1b,
            Named::Backspace => 0xff08,
            Named::Delete => 0xffff,
            Named::Up => 0xff52,
            Named::Down => 0xff54,
            Named::Left => 0xff51,
            Named::Right => 0xff53,
            Named::Home => 0xff50,
            Named::End => 0xff57,
            Named::PageUp => 0xff55,
            Named::PageDown => 0xff56,
            Named::Insert => 0xff63,
            Named::Help => 0xff6a,
            Named::Menu => 0xff67,
            Named::CapsLock => 0xffe5,
            Named::NumLock => 0xff7f,
            Named::PrintScreen => 0xff61,
            Named::F(n) => 0xffbe + (n as u32 - 1),
            Named::KpEnter => 0xff8d,
            Named::Kp(c) => match c {
                '0'..='9' => 0xffb0 + (c as u32 - '0' as u32),
                '.' => 0xffae,
                '+' => 0xffab,
                '-' => 0xffad,
                '*' => 0xffaa,
                '/' => 0xffaf,
                _ => 0xffbd,
            },
            Named::Ctrl => 0xffe3,
            Named::Alt => 0xffe9,
            Named::Shift => 0xffe1,
            Named::Super => 0xffeb,
        },
    }
}

const MOD_KEYSYMS: [u32; 4] = [0xffe3, 0xffe9, 0xffe1, 0xffeb];

fn press_chord(r: &Real, chord: &Chord) -> bool {
    let needs_shift = matches!(chord.key, Key::Char(c) if c.is_ascii_uppercase()) && !chord.mods.shift;
    match r {
        Real::X(xs) => {
            press_chord_x(xs, chord);
            true
        }
        Real::W(input) => {
            let held: Vec<u32> = [chord.mods.ctrl, chord.mods.alt, chord.mods.shift, chord.mods.super_].iter().zip(MOD_KEYSYMS).filter(|(on, _)| **on).map(|(_, k)| k).collect();
            input.chord(&held, keysym_of(chord.key), needs_shift)
        }
    }
}

fn tap(r: &Real, keysym: u32) -> bool {
    match r {
        Real::X(xs) => xs.tap_keysym(keysym, false),
        Real::W(input) => input.chord(&[], keysym, false),
    }
}

fn press_chord_x(xs: &X11, chord: &Chord) {
    let mut held = vec![];
    for (on, sym) in [(chord.mods.ctrl, 0xffe3), (chord.mods.alt, 0xffe9), (chord.mods.shift, 0xffe1), (chord.mods.super_, 0xffeb)] {
        if on {
            if let Some((code, _)) = xs.keycode_for(sym) {
                xs.key(code, true);
                held.push(code);
            }
        }
    }
    let needs_shift = matches!(chord.key, Key::Char(c) if c.is_ascii_uppercase()) && !chord.mods.shift;
    xs.tap_keysym(keysym_of(chord.key), needs_shift);
    for code in held.into_iter().rev() {
        xs.key(code, false);
    }
}

fn type_keys(r: &Real, text: &str, ctx: &ActCtx) -> TurboResult<usize> {
    // Keys go to whatever window is in front: typing stops the moment it is not the target
    // (checked every few characters; asking the desktop costs a few milliseconds).
    let lost = std::cell::Cell::new(false);
    let typed = std::cell::Cell::new(0usize);
    let stop = || {
        if (ctx.interrupted)() {
            return true;
        }
        let k = typed.get();
        typed.set(k + 1);
        if k % 4 == 0 && !(ctx.still_front)() {
            lost.set(true);
            return true;
        }
        false
    };
    let stopped = |n: usize| {
        if lost.get() {
            TurboError::new(ErrorCode::UserActive, turbo_core::texts::lost_front(&ctx.app.name, n))
        } else {
            TurboError::new(ErrorCode::HaltedByUser, format!("Typing stopped after {n} character(s)."))
        }
    };
    let xs = match r {
        Real::X(xs) => *xs,
        Real::W(input) => {
            return input.type_text(text, &stop).map_err(|(n, c)| match c {
                None => stopped(n),
                Some(c) => TurboError::action(format!(
                    "Typed {n} character(s); the keyboard layout has no key for \"{c}\", so typing stopped there. Use fill_value or paste_text for such text."
                )),
            });
        }
    };
    let mut n = 0;
    for c in text.chars() {
        if stop() {
            return Err(stopped(n));
        }
        xs.tap_keysym(keysym_for_char(c), false);
        n += 1;
        sleep(8);
    }
    Ok(n)
}

/// Insert at the caret through EditableText; true when the text grew.
fn insert(a: &Atspi, el: &El, text: &str) -> bool {
    // Typing replaces selected text (a location bar selects its whole path when focused).
    if let Some((s, e)) = a.selection(el).filter(|(s, e)| e > s && *s >= 0) {
        if a.delete_text(el, s, e) {
            a.set_caret(el, s);
        }
    }
    let before = a.character_count(el).unwrap_or(0);
    let pos = a.caret(el).filter(|p| *p >= 0 && *p <= before).unwrap_or(before);
    if !a.insert_text(el, pos, text) {
        return false;
    }
    let after = a.character_count(el).unwrap_or(before);
    if after > before {
        a.set_caret(el, pos + text.chars().count() as i32);
        true
    } else {
        false
    }
}

fn write_text(native: &Native, ctx: &ActCtx, text: &str, el: Option<El>) -> TurboResult<String> {
    let a = native.a()?;
    let target = match el {
        Some(e) => {
            a.grab_focus(&e);
            sleep(60);
            Some(e)
        }
        None => native.focused_in(ctx.pid),
    };
    let total = text.chars().count();
    let (mut via_ax, mut via_keys) = (0usize, 0usize);
    let mut segment = String::new();
    let flush = |segment: &mut String, via_ax: &mut usize, via_keys: &mut usize| -> TurboResult<()> {
        if segment.is_empty() {
            return Ok(());
        }
        let s = std::mem::take(segment);
        if let Some(t) = &target {
            if editable(a, t) && insert(a, t, &s) {
                *via_ax += s.chars().count();
                return Ok(());
            }
        }
        let r = real(native, ctx)?;
        (ctx.borrow_front)("typing into this element (it does not take text through accessibility)")?;
        *via_keys += type_keys(&r, &s, ctx)?;
        Ok(())
    };
    for c in text.chars() {
        if c == '\n' || c == '\t' {
            flush(&mut segment, &mut via_ax, &mut via_keys)?;
            let multi = target.as_ref().is_some_and(|t| has(a.states(t), state::MULTI_LINE));
            if c == '\n' && multi && target.as_ref().is_some_and(|t| editable(a, t) && insert(a, t, "\n")) {
                via_ax += 1;
                continue;
            }
            // Return in a one-line field: a real key press where real input is available
            // (some toolkits accept a field's "activate" action and ignore it).
            if c == '\n' && real(native, ctx).is_err() {
                if let Some(t) = &target {
                    if let Some(i) = action_index(a, t, &["activate"]) {
                        if a.do_action(t, i) {
                            via_ax += 1;
                            continue;
                        }
                    }
                }
            }
            let r = real(native, ctx)?;
            (ctx.borrow_front)(if c == '\n' { "pressing Return" } else { "pressing Tab" })?;
            if !(ctx.still_front)() {
                return Err(TurboError::new(ErrorCode::UserActive, turbo_core::texts::lost_front(&ctx.app.name, via_ax + via_keys)));
            }
            tap(&r, if c == '\n' { 0xff0d } else { 0xff09 });
            via_keys += 1;
        } else {
            segment.push(c);
        }
    }
    flush(&mut segment, &mut via_ax, &mut via_keys)?;
    if via_keys > 0 {
        // Key presses become text only in something that takes text.
        let focus = native.focused_in(ctx.pid);
        let takes_text = focus.as_ref().is_some_and(|f| editable(a, f) || a.interfaces(f).iter().any(|i| i.ends_with(".Text")) && has(a.states(f), state::EDITABLE));
        if !takes_text {
            let what = focus
                .as_ref()
                .map(|f| turbo_core::events::describe(&a.role_name(f).unwrap_or_default(), a.name(f).as_deref()))
                .unwrap_or_else(|| "no element (nothing has the keyboard focus)".into());
            return Ok(turbo_core::texts::keys_to_non_text(via_keys, &what, &ctx.app.name));
        }
    }
    let how = match (via_ax > 0, via_keys > 0) {
        (true, false) => " (inserted through accessibility)",
        (true, true) => " (partly through accessibility, partly as key events)",
        _ => "",
    };
    Ok(format!("Typed {total} character(s){how}."))
}

/// UTF-16 offsets (core) → character offsets (AT-SPI).
fn utf16_to_chars(text: &str, start: usize, len: usize) -> (i32, i32) {
    let (mut u, mut s_char, mut e_char) = (0usize, None, None);
    for (i, c) in text.chars().enumerate() {
        if u == start {
            s_char = Some(i);
        }
        if u == start + len {
            e_char = Some(i);
        }
        u += c.len_utf16();
    }
    let n = text.chars().count();
    let s = s_char.unwrap_or(n);
    (s as i32, e_char.unwrap_or(n).max(s) as i32)
}

pub fn act(native: &Native, ctx: &ActCtx, step: PStep<El>) -> TurboResult<Option<String>> {
    let a = native.a()?;
    let note = match step {
        PStep::Click { target, button, times } => match target {
            ActTarget::Element { index, el } => {
                if button == Button::Left && times == 1 && !ctx.self_drawn {
                    if let Some(i) = action_index(a, &el, &["click", "press", "activate", "jump", "toggle"]) {
                        if a.do_action(&el, i) {
                            return Ok(Some(format!("Pressed #{index} with its accessibility action.")));
                        }
                    }
                }
                let Some(at) = native.element_point(ctx.pid, &el) else {
                    // No place on screen to click (a Wayland window): what a click on a field
                    // does is give it the keyboard focus.
                    if button == Button::Left && times == 1 && has(a.states(&el), state::FOCUSABLE) && a.grab_focus(&el) {
                        return Ok(Some(format!("Focused #{index} through accessibility (its place on screen is not known here, so it was not clicked).")));
                    }
                    return Err(TurboError::action(format!(
                        "Element #{index} has no action and no known place on screen; click it by its x/y in the screenshot instead."
                    )));
                };
                mouse_click(native, ctx, at, button, times)?
            }
            ActTarget::Point { x, y } => mouse_click(native, ctx, (x, y), button, times)?,
        },
        PStep::Scroll { target, direction, pages } => {
            let at = match target {
                ActTarget::Element { index, el } => native.element_point(ctx.pid, &el).ok_or_else(|| TurboError::action(format!("Element #{index} has no on-screen position.")))?,
                ActTarget::Point { x, y } => (x, y),
            };
            let r = real(native, ctx)?;
            if let Real::W(input) = &r {
                (ctx.borrow_front)("scrolling")?;
                let n = ((pages * 5.0).round() as i32).max(1);
                let (dx, dy) = match direction {
                    Direction::Up => (0, -n),
                    Direction::Down => (0, n),
                    Direction::Left => (-n, 0),
                    Direction::Right => (n, 0),
                };
                if !input.scroll(None, at.0, at.1, dx, dy) {
                    return Err(TurboError::action("The shared window offers no scrolling device right now; observe again."));
                }
                return Ok(Some(format!("Scrolled {} {pages} page(s).", format!("{direction:?}").to_lowercase())));
            }
            let xs = x(native)?;
            (ctx.need_idle)("scrolling")?;
            let b = match direction {
                Direction::Up => 4,
                Direction::Down => 5,
                Direction::Left => 6,
                Direction::Right => 7,
            };
            let clicks = ((pages * 5.0).round() as u32).max(1);
            with_pointer(xs, at, |xs| {
                for _ in 0..clicks {
                    xs.button(b, true);
                    xs.button(b, false);
                    sleep(15);
                }
            });
            ctx.note(turbo_core::texts::real_pointer_note(&ctx.app.name));
            format!("Scrolled {} {pages} page(s).", format!("{direction:?}").to_lowercase())
        }
        PStep::Drag { from, to } => {
            let r = real(native, ctx)?;
            (ctx.borrow_front)("dragging")?;
            if let Real::W(input) = &r {
                let m = None;
                input.move_to(m, from.0, from.1);
                sleep(80);
                input.button(eis::BTN_LEFT, true);
                sleep(120);
                for i in 1..=16 {
                    if (ctx.interrupted)() {
                        input.button(eis::BTN_LEFT, false);
                        return Err(TurboError::halted());
                    }
                    let t = i as f64 / 16.0;
                    input.move_to(m, from.0 + (to.0 - from.0) * t, from.1 + (to.1 - from.1) * t);
                    sleep(25);
                }
                sleep(200);
                input.button(eis::BTN_LEFT, false);
                return Ok(Some("Dragged.".into()));
            }
            let xs = x(native)?;
            let original = xs.pointer();
            xs.motion(from.0 as i16, from.1 as i16);
            sleep(80);
            xs.button(1, true);
            sleep(120);
            for i in 1..=16 {
                if (ctx.interrupted)() {
                    xs.motion(from.0 as i16, from.1 as i16);
                    xs.button(1, false);
                    return Err(TurboError::halted());
                }
                let t = i as f64 / 16.0;
                xs.motion((from.0 + (to.0 - from.0) * t) as i16, (from.1 + (to.1 - from.1) * t) as i16);
                sleep(25);
            }
            sleep(200);
            xs.button(1, false);
            sleep(150);
            if let Some((ox, oy)) = original {
                xs.warp(ox, oy);
            }
            ctx.note(turbo_core::texts::real_pointer_note(&ctx.app.name));
            "Dragged.".into()
        }
        PStep::WriteText { text, el } => write_text(native, ctx, &text, el)?,
        PStep::SendKeys { chord, shown } => {
            // Return: a real key press where real input is available (a field's "activate"
            // action is accepted but ignored by some toolkits); the action otherwise.
            if !chord.mods.any() && matches!(chord.key, Key::Named(Named::Return) | Key::Named(Named::KpEnter)) && real(native, ctx).is_err() {
                if let Some(f) = native.focused_in(ctx.pid) {
                    if let Some(i) = action_index(a, &f, &["activate"]) {
                        if a.do_action(&f, i) {
                            return Ok(Some(format!("Pressed {shown} through the focused element's accessibility action.")));
                        }
                    }
                }
            }
            let r = real(native, ctx)?;
            (ctx.borrow_front)(&format!("the key press \"{shown}\""))?;
            if !(ctx.still_front)() {
                return Err(TurboError::new(ErrorCode::UserActive, turbo_core::texts::lost_front(&ctx.app.name, 0)));
            }
            if !press_chord(&r, &chord) {
                return Err(TurboError::action(format!("The keyboard layout has no key for {shown}; nothing was pressed.")));
            }
            format!("Pressed {shown}.")
        }
        PStep::FillValue { el, value } => {
            let trimmed = value.trim();
            let ifaces = a.interfaces(&el);
            let ok = if ifaces.iter().any(|i| i.ends_with("Value")) && trimmed.parse::<f64>().is_ok() {
                a.set_value(&el, trimmed.parse().unwrap())
            } else if editable(a, &el) {
                a.set_text(&el, &value)
            } else if let Some(want) = match trimmed.to_lowercase().as_str() {
                "1" | "true" | "yes" | "on" | "checked" | "selected" => Some(true),
                "0" | "false" | "no" | "off" | "unchecked" | "unselected" => Some(false),
                _ => None,
            } {
                let is = has(a.states(&el), state::CHECKED);
                is == want || action_index(a, &el, &["toggle", "click", "press"]).is_some_and(|i| a.do_action(&el, i))
            } else {
                return Err(TurboError::new(ErrorCode::NotSupported, "The value of this element is not settable; try click_at + write_text instead."));
            };
            if !ok {
                return Err(TurboError::action("Setting the value failed."));
            }
            sleep(150);
            let now = a.text(&el).or_else(|| a.value(&el).map(|v| v.to_string())).unwrap_or_default();
            if editable(a, &el) && now.trim() != value.trim() {
                format!("The value was set, but the element now reads \"{}\" (the app may have reverted or reformatted it).", turbo_core::protocol::clean(&now, 80))
            } else {
                return Ok(None);
            }
        }
        PStep::PickText { el, start, len, mode } => {
            a.grab_focus(&el);
            let text = a.text(&el).unwrap_or_default();
            let (s, e) = utf16_to_chars(&text, start, len);
            let ok = match mode {
                Caret::Select => a.select(&el, s, e),
                Caret::Before => a.set_caret(&el, s),
                Caret::After => a.set_caret(&el, e),
            };
            if !ok {
                return Err(TurboError::action("Selecting the text through accessibility failed."));
            }
            return Ok(None);
        }
        PStep::InvokeAction { el, name } => {
            let names = a.actions(&el);
            let want = norm(&name);
            if let Some(i) = names.iter().position(|n| norm(n) == want || super::action_display(n).is_some_and(|d| norm(&d) == want)) {
                if !a.do_action(&el, i as i32) {
                    return Err(TurboError::action(format!("Performing {name} failed.")));
                }
                return Ok(None);
            }
            if want == "raise" {
                (ctx.borrow_front)("switching to that window")?;
                return Ok(Some("Raised the window.".into()));
            }
            let shown: Vec<String> = names.iter().filter_map(|n| super::action_display(n).or_else(|| Some(n.clone()))).collect();
            return Err(TurboError::new(ErrorCode::NotSupported, format!("Action \"{}\" is not available here. Available: {}.", turbo_core::protocol::clean(&name, 60), if shown.is_empty() { "none".into() } else { shown.join(", ") })));
        }
        PStep::PasteText { text, format } => {
            let plain = paste_plain(&text, format);
            let n = write_text(native, ctx, &plain, None)?;
            if format == turbo_core::steps::PasteFormat::Text {
                n
            } else {
                format!("{n} Rich formatting is inserted as plain text on Linux.")
            }
        }
        PStep::RunCommand { path } => {
            let shown = turbo_core::events::display_path(&path);
            let (el, found, action) = native
                .command_element(ctx.app, &path)
                .ok_or_else(|| TurboError::bad(format!("{} has no menu command {shown} right now; call find_command to see the current commands.", ctx.app.name)))?;
            if !found.enabled {
                return Err(TurboError::action(format!(
                    "The command {} is unavailable (greyed out) in {} right now: it may need a selection or an open document, or a dialog of the app is open. Nothing was pressed.",
                    turbo_core::events::display_path(&found.path),
                    ctx.app.name
                )));
            }
            let i = action.or_else(|| action_index(a, &el, &["click", "activate", "press"])).unwrap_or(0);
            if !a.do_action(&el, i) {
                return Err(TurboError::action(format!("Pressing the menu command {shown} failed.")));
            }
            format!("Ran the menu command {} through accessibility; {} stayed in the background.", turbo_core::events::display_path(&found.path), ctx.app.name)
        }
    };
    Ok(Some(note))
}
