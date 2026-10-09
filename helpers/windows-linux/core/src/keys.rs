//! Key chords in xdotool "key" syntax (`sendKeys`), platform-neutral.
//!
//! On Windows and Linux `cmd` / `command` mean the primary shortcut modifier, Ctrl (agents
//! often think in macOS shortcuts: cmd+s saves everywhere); `super` / `win` / `meta` is the
//! Windows / Super key.

use crate::errors::TurboError;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Mods {
    pub ctrl: bool,
    pub alt: bool,
    pub shift: bool,
    pub super_: bool,
}

impl Mods {
    pub fn any(&self) -> bool {
        self.ctrl || self.alt || self.shift || self.super_
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Named {
    Return,
    Tab,
    Space,
    Escape,
    Backspace,
    Delete,
    Up,
    Down,
    Left,
    Right,
    Home,
    End,
    PageUp,
    PageDown,
    Insert,
    Help,
    Menu,
    CapsLock,
    NumLock,
    PrintScreen,
    F(u8),
    Kp(char),
    KpEnter,
    Ctrl,
    Alt,
    Shift,
    Super,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Key {
    Char(char),
    Named(Named),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Chord {
    pub mods: Mods,
    pub key: Key,
}

fn punct(name: &str) -> Option<char> {
    Some(match name {
        "exclam" => '!',
        "quotedbl" => '"',
        "numbersign" => '#',
        "dollar" => '$',
        "percent" => '%',
        "ampersand" => '&',
        "apostrophe" | "quoteright" => '\'',
        "parenleft" => '(',
        "parenright" => ')',
        "asterisk" => '*',
        "plus" => '+',
        "comma" => ',',
        "minus" => '-',
        "period" => '.',
        "slash" => '/',
        "colon" => ':',
        "semicolon" => ';',
        "less" => '<',
        "equal" => '=',
        "greater" => '>',
        "question" => '?',
        "at" => '@',
        "bracketleft" => '[',
        "backslash" => '\\',
        "bracketright" => ']',
        "asciicircum" => '^',
        "underscore" => '_',
        "grave" | "quoteleft" => '`',
        "braceleft" => '{',
        "bar" => '|',
        "braceright" => '}',
        "asciitilde" => '~',
        _ => return None,
    })
}

fn named(raw: &str) -> Option<Named> {
    let n = raw.to_lowercase();
    Some(match n.as_str() {
        "return" | "enter" | "linefeed" => Named::Return,
        "tab" => Named::Tab,
        "space" => Named::Space,
        "escape" | "esc" => Named::Escape,
        "backspace" => Named::Backspace,
        // xdotool: "Delete" (exactly) is forward delete; any other spelling is Backspace.
        "delete" if raw == "Delete" => Named::Delete,
        "delete" => Named::Backspace,
        "forward_delete" | "del" => Named::Delete,
        "up" => Named::Up,
        "down" => Named::Down,
        "left" => Named::Left,
        "right" => Named::Right,
        "home" | "begin" => Named::Home,
        "end" => Named::End,
        "page_up" | "pageup" | "pgup" | "prior" => Named::PageUp,
        "page_down" | "pagedown" | "pgdn" | "next" => Named::PageDown,
        "insert" => Named::Insert,
        "help" => Named::Help,
        "menu" => Named::Menu,
        "caps_lock" => Named::CapsLock,
        "num_lock" | "clear" => Named::NumLock,
        "print" | "printscreen" => Named::PrintScreen,
        "kp_enter" => Named::KpEnter,
        "kp_decimal" | "kp_separator" => Named::Kp('.'),
        "kp_add" => Named::Kp('+'),
        "kp_subtract" => Named::Kp('-'),
        "kp_multiply" => Named::Kp('*'),
        "kp_divide" => Named::Kp('/'),
        "kp_equal" => Named::Kp('='),
        "kp_up" => Named::Up,
        "kp_down" => Named::Down,
        "kp_left" => Named::Left,
        "kp_right" => Named::Right,
        "kp_home" => Named::Home,
        "kp_end" => Named::End,
        "kp_prior" | "kp_page_up" => Named::PageUp,
        "kp_next" | "kp_page_down" => Named::PageDown,
        "kp_insert" => Named::Insert,
        "kp_delete" => Named::Delete,
        _ => {
            if let Some(d) = n.strip_prefix("kp_").and_then(|d| d.parse::<u8>().ok()).filter(|d| *d <= 9) {
                return Some(Named::Kp((b'0' + d) as char));
            }
            if let Some(f) = n.strip_prefix('f').and_then(|d| d.parse::<u8>().ok()).filter(|f| (1..=24).contains(f)) {
                return Some(Named::F(f));
            }
            return None;
        }
    })
}

/// Modifier tokens → which modifier, plus the key it stands for when pressed alone.
fn modifier(token: &str) -> Option<(fn(&mut Mods), Named)> {
    let t = token.to_lowercase();
    let t = t.trim_end_matches("_l").trim_end_matches("_r");
    Some(match t {
        "cmd" | "command" | "ctrl" | "control" => (|m: &mut Mods| m.ctrl = true, Named::Ctrl),
        "alt" | "option" | "opt" => (|m: &mut Mods| m.alt = true, Named::Alt),
        "shift" => (|m: &mut Mods| m.shift = true, Named::Shift),
        "super" | "win" | "meta" => (|m: &mut Mods| m.super_ = true, Named::Super),
        _ => return None,
    })
}

pub fn parse(input: &str) -> Result<Chord, TurboError> {
    let raw = input.trim();
    if raw.is_empty() {
        return Err(TurboError::bad("key must not be empty"));
    }
    // Aliases.
    match raw.to_lowercase().as_str() {
        "undo" => return parse("ctrl+z"),
        "redo" => return parse("ctrl+shift+z"),
        "find" => return parse("ctrl+f"),
        "iso_left_tab" => return parse("shift+Tab"),
        _ => {}
    }
    let mut tokens: Vec<String> = raw.split('+').map(|s| s.trim().to_string()).collect();
    // "ctrl++" → the last key is '+'.
    if raw.ends_with("++") {
        tokens.retain(|t| !t.is_empty());
        tokens.push("+".into());
    }
    if tokens.iter().any(|t| t.is_empty()) {
        return Err(TurboError::bad(format!("Invalid key chord \"{}\"", crate::protocol::clean(raw, 40))));
    }
    let mut mods = Mods::default();
    let (last, rest) = tokens.split_last().unwrap();
    for t in rest {
        let (set, _) = modifier(t)
            .ok_or_else(|| TurboError::bad(format!("Unknown modifier \"{}\" in \"{}\"", crate::protocol::clean(t, 20), crate::protocol::clean(raw, 40))))?;
        set(&mut mods);
    }
    if let Some((_, named_mod)) = modifier(last) {
        return Ok(Chord { mods, key: Key::Named(named_mod) });
    }
    if last.eq_ignore_ascii_case("hyper") {
        return Ok(Chord { mods: Mods { ctrl: true, alt: true, shift: true, super_: true }, key: Key::Named(Named::Super) });
    }
    let key = if last.chars().count() == 1 {
        Key::Char(last.chars().next().unwrap())
    } else if let Some(c) = punct(&last.to_lowercase()) {
        Key::Char(c)
    } else if let Some(n) = named(last) {
        Key::Named(n)
    } else {
        return Err(TurboError::bad(format!("Unknown key \"{}\" in \"{}\"", crate::protocol::clean(last, 30), crate::protocol::clean(raw, 40))));
    };
    Ok(Chord { mods, key })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chords() {
        let c = parse("cmd+shift+z").unwrap();
        assert!(c.mods.ctrl && c.mods.shift && c.key == Key::Char('z'));
        assert_eq!(parse("Return").unwrap().key, Key::Named(Named::Return));
        assert_eq!(parse("Delete").unwrap().key, Key::Named(Named::Delete));
        assert_eq!(parse("delete").unwrap().key, Key::Named(Named::Backspace));
        assert_eq!(parse("ctrl++").unwrap().key, Key::Char('+'));
        assert_eq!(parse("KP_7").unwrap().key, Key::Named(Named::Kp('7')));
        assert_eq!(parse("F12").unwrap().key, Key::Named(Named::F(12)));
        assert_eq!(parse("bracketleft").unwrap().key, Key::Char('['));
        assert!(parse("ctrl+nope").is_err());
        assert!(parse("bogus+a").is_err());
        assert_eq!(parse("Shift_L").unwrap().key, Key::Named(Named::Shift));
    }
}
