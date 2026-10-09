//! What happens in an app between two looks (and while waiting) and the
//! app's menu commands: platform-neutral types, the per-app event log
//! the platform layers fill, the "Since your last look" summary and `waitFor` conditions.

use std::collections::HashMap;
use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use crate::errors::TurboError;
use crate::protocol::clean;
use crate::tree::Node;

// ---------------------------------------------------------------- events

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum EventKind {
    WindowOpened,
    DialogOpened,
    WindowClosed,
    MenuOpened,
    MenuClosed,
    FocusMoved,
    ValueChanged,
    TitleChanged,
    SelectionChanged,
    PageLoaded,
    Announcement,
}

impl EventKind {
    /// Higher = kept first when there are more events than room.
    fn weight(self) -> u8 {
        match self {
            Self::Announcement | Self::DialogOpened => 5,
            Self::WindowOpened | Self::WindowClosed | Self::PageLoaded => 4,
            Self::ValueChanged | Self::TitleChanged => 3,
            Self::MenuOpened | Self::MenuClosed | Self::SelectionChanged => 2,
            Self::FocusMoved => 1,
        }
    }

    fn verb(self) -> &'static str {
        match self {
            Self::WindowOpened => "window opened",
            Self::DialogOpened => "dialog opened",
            Self::WindowClosed => "window closed",
            Self::MenuOpened => "menu opened",
            Self::MenuClosed => "menu closed",
            Self::FocusMoved => "focus moved to",
            Self::ValueChanged => "value changed",
            Self::TitleChanged => "title changed",
            Self::SelectionChanged => "selection changed in",
            Self::PageLoaded => "page finished loading",
            Self::Announcement => "announced",
        }
    }

    /// One entry per element for kinds that keep changing (typing, progress bars).
    fn coalesces(self) -> bool {
        matches!(self, Self::ValueChanged | Self::TitleChanged | Self::FocusMoved | Self::SelectionChanged)
    }
}

/// One described event. `what`: the element ("text field \"Name\""); `detail`: its new value or
/// the announced text — platforms never put a password field's value here.
#[derive(Clone, Debug, PartialEq)]
pub struct UiEvent {
    pub at: Instant,
    pub kind: EventKind,
    pub what: Option<String>,
    pub detail: Option<String>,
    /// Identity of the element, for folding repeats (not shown).
    pub key: Option<String>,
}

impl UiEvent {
    pub fn new(kind: EventKind) -> Self {
        Self { at: Instant::now(), kind, what: None, detail: None, key: None }
    }
    pub fn what(mut self, w: impl Into<String>) -> Self {
        let w = w.into();
        if !w.trim().is_empty() {
            self.what = Some(w);
        }
        self
    }
    pub fn detail(mut self, d: Option<String>) -> Self {
        self.detail = d.filter(|d| !d.is_empty());
        self
    }
    pub fn key(mut self, k: impl Into<String>) -> Self {
        self.key = Some(k.into());
        self
    }

    pub fn line(&self) -> String {
        let mut s = self.kind.verb().to_string();
        if let Some(w) = &self.what {
            s.push(' ');
            s.push_str(w);
        }
        if let Some(d) = &self.detail {
            if self.kind == EventKind::Announcement {
                s.push_str(&format!(" \"{}\"", clean(d, 160)));
            } else {
                s.push_str(&format!(" → \"{}\"", clean(d, 80)));
            }
        }
        s
    }
}

/// Small helper windows — floating buttons and badges shown next to a window (writing
/// assistants, input-method badges) — are not windows the user works in: never reported as
/// opened windows or dialogs.
pub fn incidental_window(width: f64, height: f64) -> bool {
    width < 200.0 || height < 100.0
}

/// A menu item the app fills in itself rather than a command: a recent-file entry ("1 report.txt",
/// a path) — the convention of Windows and Linux toolkits. Such items are content, so they are
/// never listed or saved.
pub fn looks_app_filled(title: &str) -> bool {
    let t = display_title(title);
    let t = t.trim();
    let numbered = t.split_once(' ').is_some_and(|(n, rest)| !n.is_empty() && n.len() <= 2 && n.chars().all(|c| c.is_ascii_digit()) && !rest.is_empty());
    let path = t.starts_with('/') || t.starts_with("~/") || t.contains(":\\") || t.starts_with("\\\\");
    numbered || path
}

/// "role \"label\"" for event lines.
pub fn describe(role: &str, label: Option<&str>) -> String {
    match label.map(str::trim).filter(|l| !l.is_empty()) {
        Some(l) => format!("{role} \"{}\"", clean(l, 60)),
        None => role.to_string(),
    }
}

const MAX_PER_APP: usize = 400;

/// Events per process, filled by the platform's event thread, read by the service.
#[derive(Default)]
pub struct EventLog {
    inner: Mutex<HashMap<u32, Vec<UiEvent>>>,
    last: Mutex<HashMap<u32, Instant>>,
    wake: Condvar,
}

impl EventLog {
    /// Record that something happened in `pid` (wakes waits) and, if given, what.
    pub fn push(&self, pid: u32, event: Option<UiEvent>) {
        let now = Instant::now();
        if let Some(mut e) = event {
            e.at = now;
            let mut map = self.inner.lock().unwrap();
            let log = map.entry(pid).or_default();
            if e.kind.coalesces() {
                if let Some(i) = log.iter().rposition(|x| x.kind == e.kind && (e.kind == EventKind::FocusMoved || (x.key.is_some() && x.key == e.key))) {
                    log.remove(i);
                }
            }
            log.push(e);
            if log.len() > MAX_PER_APP {
                let extra = log.len() - MAX_PER_APP;
                log.drain(..extra);
            }
        }
        self.last.lock().unwrap().insert(pid, now);
        self.wake.notify_all();
    }

    pub fn last(&self, pid: u32) -> Option<Instant> {
        self.last.lock().unwrap().get(&pid).copied()
    }

    pub fn since(&self, pid: u32, since: Instant) -> Vec<UiEvent> {
        self.inner.lock().unwrap().get(&pid).map(|v| v.iter().filter(|e| e.at > since).cloned().collect()).unwrap_or_default()
    }

    /// Wait (≤ `timeout`) for anything from `pid` newer than `after`.
    pub fn wait(&self, pid: u32, after: Instant, timeout: Duration) -> bool {
        let until = Instant::now() + timeout;
        let mut guard = self.last.lock().unwrap();
        loop {
            if guard.get(&pid).is_some_and(|t| *t > after) {
                return true;
            }
            let now = Instant::now();
            if now >= until {
                return false;
            }
            guard = self.wake.wait_timeout(guard, until - now).unwrap().0;
        }
    }

}

/// Lines for at most `limit` events: repeats folded (latest wins), the most telling kinds
/// kept when there are too many, in the order they happened.
pub fn summary(events: &[UiEvent], limit: usize) -> Vec<String> {
    let mut kept: Vec<UiEvent> = vec![];
    for e in events {
        let same = |x: &UiEvent| {
            x.kind == e.kind
                && match e.kind {
                    EventKind::FocusMoved => true,
                    k if k.coalesces() => x.what == e.what,
                    _ => x.what == e.what && x.detail == e.detail,
                }
        };
        if let Some(i) = kept.iter().position(same) {
            kept.remove(i);
        }
        kept.push(e.clone());
    }
    let dropped = kept.len().saturating_sub(limit);
    if dropped > 0 {
        let mut order: Vec<usize> = (0..kept.len()).collect();
        order.sort_by(|a, b| kept[*b].kind.weight().cmp(&kept[*a].kind.weight()).then(b.cmp(a)));
        let keep: std::collections::HashSet<usize> = order.into_iter().take(limit).collect();
        kept = kept.into_iter().enumerate().filter(|(i, _)| keep.contains(i)).map(|(_, e)| e).collect();
    }
    let mut out: Vec<String> = kept.iter().map(|e| format!("- {}", e.line())).collect();
    if dropped > 0 {
        out.push(format!("- … and {dropped} more change(s)"));
    }
    out
}

pub fn since_last_look(events: &[UiEvent]) -> Vec<String> {
    let body = summary(events, 12);
    if body.is_empty() {
        return body;
    }
    let mut out = vec!["Since your last look:".to_string()];
    out.extend(body);
    out
}

// ---------------------------------------------------------------- waitFor

#[derive(Clone, Debug, PartialEq)]
pub enum WaitCondition {
    TextAppears(String),
    TextGone(String),
    ElementChanges(usize),
    NewWindow,
    Settled,
    AnyChange,
}

pub const MAX_WAIT_MS: u64 = 60_000;
pub const DEFAULT_WAIT_MS: u64 = 10_000;

impl WaitCondition {
    pub fn parse(payload: &Value) -> Result<Self, TurboError> {
        let until = payload.get("until").and_then(Value::as_str).ok_or_else(|| {
            TurboError::bad("waitFor requires until: textAppears, textGone, elementChanges, newWindow, settled or anyChange")
        })?;
        let text = || -> Result<String, TurboError> {
            payload
                .get("text")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|t| !t.is_empty() && t.chars().count() <= 500)
                .map(str::to_string)
                .ok_or_else(|| TurboError::bad(format!("{until} requires a non-empty text (at most 500 characters)")))
        };
        Ok(match until {
            "textAppears" => Self::TextAppears(text()?),
            "textGone" => Self::TextGone(text()?),
            "elementChanges" => Self::ElementChanges(
                payload
                    .get("elementNumber")
                    .and_then(Value::as_u64)
                    .ok_or_else(|| TurboError::bad("elementChanges requires elementNumber from the latest observation"))? as usize,
            ),
            "newWindow" => Self::NewWindow,
            "settled" => Self::Settled,
            "anyChange" => Self::AnyChange,
            other => {
                return Err(TurboError::bad(format!(
                    "Unknown until \"{}\": use textAppears, textGone, elementChanges, newWindow, settled or anyChange",
                    clean(other, 40)
                )))
            }
        })
    }

    pub fn timeout(payload: &Value) -> Result<Duration, TurboError> {
        match payload.get("timeoutMs") {
            None | Some(Value::Null) => Ok(Duration::from_millis(DEFAULT_WAIT_MS)),
            Some(v) => v
                .as_u64()
                .filter(|ms| (100..=MAX_WAIT_MS).contains(ms))
                .map(Duration::from_millis)
                .ok_or_else(|| TurboError::bad(format!("timeoutMs must be 100-{MAX_WAIT_MS}"))),
        }
    }
}

fn squash(s: &str) -> String {
    s.to_lowercase().split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Case- and space-insensitive containment.
pub fn contains_text(haystack: &str, needle: &str) -> bool {
    squash(haystack).contains(&squash(needle))
}

/// Every user-visible string of a tree; password field values are never read.
pub fn texts(roots: &[Node]) -> Vec<String> {
    fn walk(n: &Node, out: &mut Vec<String>) {
        for s in [&n.title, &n.description, &n.placeholder].into_iter().flatten() {
            if !s.is_empty() {
                out.push(s.clone());
            }
        }
        if !n.secure {
            if let Some(v) = n.value.as_ref().filter(|v| !v.is_empty()) {
                out.push(v.clone());
            }
        }
        for c in &n.children {
            walk(c, out);
        }
    }
    let mut out = vec![];
    for r in roots {
        walk(r, &mut out);
    }
    out
}

// ---------------------------------------------------------------- commands

/// One menu command: its path of titles (menu first) and shortcut in `send_keys` syntax.
#[derive(Clone, Debug, PartialEq)]
pub struct Command {
    pub path: Vec<String>,
    pub shortcut: Option<String>,
    pub enabled: Option<bool>,
}

impl Command {
    pub fn json(&self) -> Value {
        let mut o = json!({ "path": self.path });
        if let Some(s) = &self.shortcut {
            o["shortcut"] = json!(s);
        }
        if let Some(e) = self.enabled {
            o["enabled"] = json!(e);
        }
        o
    }
}

#[derive(Default)]
pub struct MenuRead {
    pub commands: Vec<Command>,
    pub truncated: bool,
}

/// A command found live by its path.
pub struct Located {
    pub path: Vec<String>,
    pub enabled: bool,
    pub has_submenu: bool,
}

/// Menu titles as the agent names them: case, surrounding space, a trailing "…" / "..." and
/// accelerator markers ("&File", "_File") do not matter.
pub fn normalize_title(s: &str) -> String {
    let mut t = s.trim().to_string();
    if let Some(i) = t.find('\t') {
        t.truncate(i); // Windows menus: "Save\tCtrl+S"
    }
    let mut t = t.trim().to_string();
    loop {
        if let Some(x) = t.strip_suffix('…') {
            t = x.trim_end().to_string();
        } else if let Some(x) = t.strip_suffix("...") {
            t = x.trim_end().to_string();
        } else {
            break;
        }
    }
    let mut out = String::new();
    let mut chars = t.chars().peekable();
    while let Some(c) = chars.next() {
        if (c == '&' || c == '_') && chars.peek().is_some_and(|n| !n.is_whitespace()) {
            if chars.peek() == Some(&c) {
                out.push(c);
                chars.next();
            }
            continue;
        }
        out.push(c);
    }
    out.to_lowercase()
}

pub fn same_title(a: &str, b: &str) -> bool {
    normalize_title(a) == normalize_title(b)
}

/// The title as shown: accelerator markers and a Windows "\tShortcut" removed.
pub fn display_title(s: &str) -> String {
    let t = s.split('\t').next().unwrap_or("").trim();
    let mut out = String::new();
    let mut chars = t.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '&' {
            if chars.peek() == Some(&'&') {
                out.push('&');
                chars.next();
            }
            continue;
        }
        out.push(c);
    }
    out
}

pub fn display_path(path: &[String]) -> String {
    path.iter().map(|t| clean(t, 80)).collect::<Vec<_>>().join(" ▸ ")
}

/// Validate a `runCommand` path: 1-8 non-empty titles of at most 300 characters.
pub fn parse_path(v: Option<&Value>) -> Result<Vec<String>, TurboError> {
    let items = v.and_then(Value::as_array).ok_or_else(|| TurboError::bad("runCommand requires path: an array of menu titles, e.g. [\"File\", \"Export…\"]"))?;
    let titles: Vec<String> = items.iter().filter_map(Value::as_str).map(|s| s.trim().to_string()).collect();
    if titles.len() != items.len() || !(1..=8).contains(&titles.len()) || titles.iter().any(|t| t.is_empty() || t.chars().count() > 300) {
        return Err(TurboError::bad("runCommand path must be 1-8 non-empty menu titles (strings)"));
    }
    Ok(titles)
}

/// "Ctrl+Shift+S" (a Windows menu's text after the tab, or a toolkit accelerator) in
/// `send_keys` syntax: "ctrl+shift+s".
pub fn shortcut_text(raw: &str) -> Option<String> {
    let raw = raw.trim();
    if raw.is_empty() {
        return None;
    }
    let parts: Vec<&str> = raw.split('+').map(str::trim).filter(|p| !p.is_empty()).collect();
    if parts.is_empty() {
        return None;
    }
    let mut out = vec![];
    for (i, p) in parts.iter().enumerate() {
        let low = p.to_lowercase();
        let last = i == parts.len() - 1;
        out.push(match low.as_str() {
            "ctrl" | "control" | "primary" if !last => "ctrl".to_string(),
            "shift" if !last => "shift".to_string(),
            "alt" if !last => "alt".to_string(),
            "super" | "win" | "meta" if !last => "super".to_string(),
            "del" => "Delete".into(),
            "ins" => "Insert".into(),
            "enter" | "return" => "Return".into(),
            "esc" | "escape" => "Escape".into(),
            "pgup" | "page up" | "pageup" | "prior" => "Page_Up".into(),
            "pgdn" | "page down" | "pagedown" | "next" => "Page_Down".into(),
            "backspace" => "BackSpace".into(),
            "space" => "space".into(),
            "tab" => "Tab".into(),
            "plus" => "plus".into(),
            "minus" => "minus".into(),
            _ if low.len() > 1 && low.starts_with('f') && low[1..].parse::<u8>().is_ok() => p.to_uppercase(),
            _ if low.chars().count() == 1 => low,
            _ => p.to_string(),
        });
    }
    Some(out.join("+"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn titles() {
        assert!(same_title("&Save As...", "save as"));
        assert!(same_title("Export As PDF…", "export as pdf"));
        assert!(same_title("_File", "File"));
        assert_eq!(display_title("&Save\tCtrl+S"), "Save");
        assert_eq!(normalize_title("Save\tCtrl+S"), "save");
    }

    #[test]
    fn app_filled() {
        assert!(looks_app_filled("&1 C:\\Users\\me\\notes.txt"));
        assert!(looks_app_filled("2 report.txt"));
        assert!(looks_app_filled("/home/me/a.txt"));
        assert!(!looks_app_filled("Save As..."));
        assert!(!looks_app_filled("100%"));
        assert!(!looks_app_filled("Zoom 200%"));
    }

    #[test]
    fn shortcuts() {
        assert_eq!(shortcut_text("Ctrl+Shift+S").as_deref(), Some("ctrl+shift+s"));
        assert_eq!(shortcut_text("Ctrl+Del").as_deref(), Some("ctrl+Delete"));
        assert_eq!(shortcut_text("F5").as_deref(), Some("F5"));
        assert_eq!(shortcut_text("").as_deref(), None);
    }

    #[test]
    fn log_folds_and_summarises() {
        let log = EventLog::default();
        let start = Instant::now();
        std::thread::sleep(Duration::from_millis(2));
        log.push(7, Some(UiEvent::new(EventKind::ValueChanged).what("text field \"A\"").detail(Some("1".into())).key("e1")));
        log.push(7, Some(UiEvent::new(EventKind::ValueChanged).what("text field \"A\"").detail(Some("12".into())).key("e1")));
        log.push(7, Some(UiEvent::new(EventKind::DialogOpened).what("\"Save\"")));
        let ev = log.since(7, start);
        assert_eq!(ev.len(), 2);
        let lines = since_last_look(&ev);
        assert_eq!(lines[0], "Since your last look:");
        assert!(lines[1].contains("→ \"12\""));
        assert!(lines[2].contains("dialog opened \"Save\""));
        assert!(log.wait(7, start, Duration::from_millis(10)));
        assert!(!log.wait(7, Instant::now(), Duration::from_millis(10)));
    }

    #[test]
    fn conditions() {
        assert_eq!(WaitCondition::parse(&json!({"until": "textAppears", "text": " Done "})).unwrap(), WaitCondition::TextAppears("Done".into()));
        assert!(WaitCondition::parse(&json!({"until": "textAppears"})).is_err());
        assert!(WaitCondition::timeout(&json!({"timeoutMs": 50})).is_err());
        assert!(contains_text("Upload   Complete!", "upload complete"));
    }
}
