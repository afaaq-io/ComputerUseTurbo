//! Linux platform layer: AT-SPI for the UI tree and background actions (X11 and Wayland).
//! Screenshots and — only when needed — real input: X11 windows (also XWayland ones) through
//! X11 and XTest; Wayland windows through a portal session sharing the window (PipeWire
//! frames, EIS input), approved once per app by the user.

mod atspi;
mod eis;
mod events;
mod input;
mod menus;
mod pointer;
mod portal;
mod screencast;
mod wayland;
pub use wayland::share_screen_once;
mod x11;

use std::collections::HashMap;
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use atspi::{coord, has, state, Atspi, El};
use image::RgbaImage;
use turbo_core::agent::AgentIdentity;
use turbo_core::errors::{ErrorCode, TurboError, TurboResult};
use turbo_core::events::{EventLog, Located, MenuRead};
use turbo_core::platform::{ActCtx, AppEntry, AppRef, PStep, Permissions, Platform, Rect, Snapshot, WindowInfo};
use turbo_core::tree::Node;
use x11::{InputMonitor, X11};

pub struct Native {
    atspi: Option<Atspi>,
    x11: Option<X11>,
    /// Wayland session: windows of apps without an X11 window are reached through `wl`.
    wayland: bool,
    /// When the helper switched accessibility on itself: apps started before then expose
    /// nothing until they restart.
    a11y_switched_on: Option<std::time::SystemTime>,
    wl: Option<wayland::Links>,
    pointer: pointer::Pointer,
    input: Arc<InputMonitor>,
    session: Option<zbus::blocking::Connection>,
    own_pid: u32,
    events: events::Events,
    /// Modal windows of other processes when an action on an app started (pid → keys): one
    /// that appears afterwards opened for that app (a system file chooser, through a portal).
    modal_baseline: Mutex<HashMap<u32, std::collections::HashSet<String>>>,
    /// Those dialogs, per app: (owner pid, window).
    lent: Mutex<HashMap<u32, Vec<(u32, El)>>>,
}

const MAX_NODES: usize = 2500;

/// Window handle bits for Wayland windows (no X11 id): the screen is shared (the frame is the
/// desktop, x/y are desktop pixels) or not (window coordinates, no screenshot). The low bits
/// hold the pid.
const WL_SHARED: u64 = 1 << 62;
const WL_UNSHARED: u64 = 1 << 61;

impl Native {
    pub fn new(on_esc: Arc<dyn Fn() + Send + Sync>) -> Self {
        let atspi = Atspi::connect().map_err(|e| turbo_core::log::error(format!("AT-SPI unavailable: {e}"))).ok();
        let a11y_switched_on = atspi.as_ref().and_then(switch_accessibility_on);
        let x11 = X11::connect();
        let wayland = wayland::session_is_wayland();
        let wl = if wayland { wayland::Links::new(turbo_core::paths::Paths::current().screen_shares()) } else { None };
        if x11.is_none() && wl.is_none() {
            turbo_core::log::error("no X11 display and no Wayland window sharing: no screenshots or real input");
        }
        Self {
            atspi,
            x11,
            wayland,
            a11y_switched_on,
            wl,
            pointer: pointer::Pointer::new(),
            input: InputMonitor::start(on_esc),
            session: zbus::blocking::Connection::session().ok(),
            own_pid: std::process::id(),
            modal_baseline: Default::default(),
            lent: Default::default(),
            events: events::Events::new(),
        }
    }

    fn a(&self) -> TurboResult<&Atspi> {
        self.atspi.as_ref().ok_or_else(|| {
            TurboError::new(ErrorCode::AccessMissing, "The accessibility bus (AT-SPI) is not available; call access_status and ask the user to enable accessibility.")
        })
    }

    fn app_element(&self, pid: u32) -> Option<El> {
        let a = self.atspi.as_ref()?;
        a.applications().into_iter().find(|el| a.pid_of(&el.bus) == Some(pid))
    }

    /// The app's focused element (bounded search of the showing tree).
    fn focused_in(&self, pid: u32) -> Option<El> {
        let a = self.atspi.as_ref()?;
        let app = self.app_element(pid)?;
        // A dialog another process opened for the app, in front, holds its keyboard focus.
        let lent: Vec<El> = self.lent.lock().unwrap().get(&pid).map(|v| v.iter().map(|(_, w)| w.clone()).filter(|w| has(a.states(w), state::ACTIVE)).collect()).unwrap_or_default();
        let mut queue = std::collections::VecDeque::from(if lent.is_empty() { a.children(&app) } else { lent });
        let mut seen = 0;
        while let Some(el) = queue.pop_front() {
            seen += 1;
            if seen > 600 {
                break;
            }
            let st = a.states(&el);
            if has(st, state::FOCUSED) {
                // A focused field may wrap a focused inner text (GTK 4 entries): the innermost
                // one holds the caret and the selection.
                let mut inner = el;
                for _ in 0..4 {
                    match a.children(&inner).into_iter().find(|c| has(a.states(c), state::FOCUSED)) {
                        Some(c) => inner = c,
                        None => break,
                    }
                }
                return Some(inner);
            }
            if has(st, state::SHOWING) || seen < 8 {
                queue.extend(a.children(&el));
            }
        }
        None
    }

    /// A Wayland window (the app has no X11 window): window coordinates, link for pixels and
    /// real input.
    pub(crate) fn native_wayland(&self, pid: u32) -> bool {
        self.wayland && self.x11.as_ref().map_or(true, |x| x.windows_of(pid).is_empty())
    }

    /// The screen link (Wayland).
    pub(crate) fn link(&self) -> Option<Arc<wayland::Link>> {
        self.wl.as_ref()?.get()
    }

    /// Centre of an element in screen points. None for a native Wayland window: where it is
    /// on screen is not known (use the screenshot's x/y there).
    pub(crate) fn element_point(&self, pid: u32, el: &El) -> Option<(f64, f64)> {
        if self.native_wayland(pid) {
            return None;
        }
        let (x, y, w, h) = self.atspi.as_ref()?.extents(el)?;
        (w > 0 && h > 0).then(|| (x as f64 + w as f64 / 2.0, y as f64 + h as f64 / 2.0))
    }

    /// The pids whose top-level window says it is active, from the accessibility tree (works
    /// for Wayland windows, which X11 cannot see). Apps report this themselves: while the
    /// front changes, two can claim it for a moment.
    fn active_pids_atspi(&self) -> Vec<u32> {
        let Some(a) = self.atspi.as_ref() else { return vec![] };
        let mut out = vec![];
        for app in a.applications() {
            if a.children(&app).iter().any(|w| has(a.states(w), state::ACTIVE)) {
                if let Some(pid) = a.pid_of(&app.bus) {
                    if !out.contains(&pid) {
                        out.push(pid);
                    }
                }
            }
        }
        out
    }

    /// Showing modal top-level windows of other processes than `pid` (and this helper).
    fn foreign_modals(&self, pid: u32) -> Vec<(u32, El)> {
        let Some(a) = self.atspi.as_ref() else { return vec![] };
        let mut out = vec![];
        for app in a.applications() {
            let Some(p) = a.pid_of(&app.bus) else { continue };
            if p == pid || p == self.own_pid {
                continue;
            }
            for t in a.children(&app) {
                let st = a.states(&t);
                if has(st, state::SHOWING) && has(st, state::MODAL) {
                    out.push((p, t));
                }
            }
        }
        out
    }

    /// Dialogs another process opened for `pid` since an action on it began (still showing).
    fn lent_dialogs(&self, pid: u32) -> Vec<(u32, El)> {
        let Some(base) = self.modal_baseline.lock().unwrap().get(&pid).cloned() else { return vec![] };
        let list: Vec<(u32, El)> = self.foreign_modals(pid).into_iter().filter(|(_, w)| !base.contains(&w.key())).collect();
        self.lent.lock().unwrap().insert(pid, list.clone());
        list
    }

    /// Bring `pid` forward on Wayland, where no app may raise another app's window: the way a
    /// person does it, with the desktop's Alt+Tab switcher (through the shared screen's
    /// keyboard). Alt+Tab with n Tabs, n = 1, 2, …, visits each window of the recently-used
    /// list once (each switch moves the chosen one to the front).
    fn activate_wayland(&self, pid: u32) -> bool {
        const MAX_APPS: usize = 8;
        // In front, and still in front a moment later (the switch has settled).
        let front_within = |ms: u64| {
            let until = Instant::now() + Duration::from_millis(ms);
            loop {
                if self.frontmost_pid() == Some(pid) && {
                    std::thread::sleep(Duration::from_millis(80));
                    self.frontmost_pid() == Some(pid)
                } {
                    return true;
                }
                if Instant::now() >= until {
                    return false;
                }
                std::thread::sleep(Duration::from_millis(40));
            }
        };
        // Activation follows a click a moment later.
        if front_within(300) {
            return true;
        }
        let Some(input) = self.link().and_then(|l| l.input().cloned()) else { return false };
        let mut seen = vec![];
        for n in 1..=MAX_APPS {
            let t = Instant::now();
            if !input.alt_tab(n) {
                return false;
            }
            if front_within(600) {
                turbo_core::log::info(format!("wayland: brought pid {pid} forward with Alt+Tab ×{n} in {} ms (before: {seen:?})", t.elapsed().as_millis()));
                return true;
            }
            seen.push(self.frontmost_pid());
        }
        turbo_core::log::info(format!("wayland: pid {pid} not reached with Alt+Tab (active: {:?})", self.frontmost_pid()));
        false
    }

    /// Idle time from the compositor (Wayland hides other clients' input from us). Our own
    /// injected input counts as idle.
    fn compositor_idle(&self) -> Option<f64> {
        let s = self.session.as_ref()?;
        let ms: u64 = s
            .call_method(Some("org.gnome.Mutter.IdleMonitor"), "/org/gnome/Mutter/IdleMonitor/Core", Some("org.gnome.Mutter.IdleMonitor"), "GetIdletime", &())
            .ok()
            .and_then(|m| m.body().deserialize::<u64>().ok())
            .or_else(|| {
                s.call_method(Some("org.freedesktop.ScreenSaver"), "/org/freedesktop/ScreenSaver", Some("org.freedesktop.ScreenSaver"), "GetSessionIdleTime", &())
                    .ok()
                    .and_then(|m| m.body().deserialize::<u32>().ok())
                    .map(u64::from)
            })?;
        let idle = ms as f64 / 1000.0;
        let ours = self.wl.as_ref().and_then(|w| w.last_input());
        if ours.is_some_and(|t| t.elapsed().as_secs_f64() <= idle + 0.4) {
            return Some(f64::MAX);
        }
        Some(idle)
    }

    /// When accessibility was switched on in this run, apps started earlier stay invisible
    /// to it until they restart: say so.
    fn restart_hint(&self, app: &str) -> String {
        match self.a11y_switched_on {
            Some(_) => format!(" Accessibility was switched on for this desktop just now; {app} has to be restarted once (quit and open it again) before its window can be read."),
            None => String::new(),
        }
    }

    fn x_window_for(&self, pid: u32, title: Option<&str>) -> Option<u32> {
        let x = self.x11.as_ref()?;
        let wins = x.windows_of(pid);
        if let Some(t) = title.filter(|t| !t.is_empty()) {
            if let Some(w) = wins.iter().find(|w| x.title(**w) == t) {
                return Some(*w);
            }
        }
        wins.into_iter().next()
    }
}

// ------------------------------------------------------------------ apps

fn exe_id(pid: u32) -> Option<String> {
    std::fs::read_link(format!("/proc/{pid}/exe"))
        .ok()
        .and_then(|p| p.file_name().map(|n| n.to_string_lossy().into_owned()))
        .map(|s| s.trim_end_matches(" (deleted)").to_string())
        .or_else(|| std::fs::read_to_string(format!("/proc/{pid}/comm")).ok().map(|s| s.trim().to_string()))
}

fn exe_path(pid: u32) -> String {
    std::fs::read_link(format!("/proc/{pid}/exe")).map(|p| p.to_string_lossy().into_owned()).unwrap_or_default()
}

#[derive(Clone, Debug)]
struct DesktopEntry {
    name: String,
    id: String,
    exec: Vec<String>,
    path: PathBuf,
}

/// Every folder where installed apps put their menu entries (desktop files), for every way
/// apps get installed: distribution packages, Snap, Flatpak, Nix, Guix, Homebrew, and what
/// Steam, Wine, Distrobox or AppImage tools add to the user's own folder.
fn desktop_dirs() -> Vec<PathBuf> {
    let home = std::env::var("HOME").unwrap_or_default();
    let user = std::env::var("USER").unwrap_or_default();
    let mut data: Vec<String> = vec![std::env::var("XDG_DATA_HOME").unwrap_or_else(|_| format!("{home}/.local/share"))];
    // The desktop session's own list (the helper may have been started with a minimal
    // environment), then ours, then the usual places of each packaging system.
    for list in [session_env("XDG_DATA_DIRS"), std::env::var("XDG_DATA_DIRS").ok()].into_iter().flatten() {
        data.extend(list.split(':').filter(|d| !d.is_empty()).map(str::to_string));
    }
    data.extend(
        [
            "/usr/local/share".to_string(),
            "/usr/share".into(),
            "/var/lib/snapd/desktop".into(),
            "/var/lib/flatpak/exports/share".into(),
            format!("{home}/.local/share/flatpak/exports/share"),
            format!("{home}/.nix-profile/share"),
            format!("{home}/.local/state/nix/profile/share"),
            format!("/etc/profiles/per-user/{user}/share"),
            "/run/current-system/sw/share".into(),
            "/nix/var/nix/profiles/default/share".into(),
            format!("{home}/.guix-profile/share"),
            "/run/current-system/profile/share".into(),
            "/home/linuxbrew/.linuxbrew/share".into(),
            format!("{home}/.linuxbrew/share"),
        ],
    );
    let mut seen = std::collections::HashSet::new();
    data.into_iter().map(|d| PathBuf::from(d).join("applications")).filter(|d| seen.insert(d.clone())).collect()
}

/// A variable of the desktop session's environment, from the user's service manager
/// (systemd), when the helper's own environment lacks it.
fn session_env(name: &str) -> Option<String> {
    let conn = zbus::blocking::Connection::session().ok()?;
    let reply = conn
        .call_method(
            Some("org.freedesktop.systemd1"),
            "/org/freedesktop/systemd1",
            Some("org.freedesktop.DBus.Properties"),
            "Get",
            &("org.freedesktop.systemd1.Manager", "Environment"),
        )
        .ok()?;
    let v: zbus::zvariant::OwnedValue = reply.body().deserialize().ok()?;
    let list: Vec<String> = v.try_into().ok()?;
    let prefix = format!("{name}=");
    list.into_iter().find_map(|e| e.strip_prefix(&prefix).map(str::to_string))
}

/// Folders where people keep AppImages that no tool has added to the menu.
fn appimage_dirs() -> Vec<PathBuf> {
    let home = std::env::var("HOME").unwrap_or_default();
    ["Applications", "AppImages", "Apps", ".local/bin", "bin"].iter().map(|d| Path::new(&home).join(d)).collect()
}

fn split_exec(exec: &str) -> Vec<String> {
    let mut out = vec![];
    let mut cur = String::new();
    let mut quoted = false;
    for c in exec.chars() {
        match c {
            '"' => quoted = !quoted,
            ' ' if !quoted => {
                if !cur.is_empty() {
                    out.push(std::mem::take(&mut cur));
                }
            }
            c => cur.push(c),
        }
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out.retain(|t| !(t.starts_with('%') && t.len() == 2));
    out
}

fn parse_desktop(path: &Path) -> Option<DesktopEntry> {
    let text = std::fs::read_to_string(path).ok()?;
    let mut in_entry = false;
    let (mut name, mut exec, mut hidden, mut app) = (None, None, false, true);
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_entry = line == "[Desktop Entry]";
            continue;
        }
        if !in_entry {
            continue;
        }
        if let Some(v) = line.strip_prefix("Name=") {
            name.get_or_insert_with(|| v.to_string());
        } else if let Some(v) = line.strip_prefix("Exec=") {
            exec = Some(v.to_string());
        } else if line == "NoDisplay=true" || line == "Hidden=true" {
            hidden = true;
        } else if let Some(v) = line.strip_prefix("Type=") {
            app = v == "Application";
        }
    }
    if hidden || !app {
        return None;
    }
    let exec = split_exec(&exec?);
    let program = exec.iter().find(|t| *t != "env" && !t.contains('='))?.clone();
    let mut id = Path::new(&program).file_name()?.to_string_lossy().into_owned();
    // Flatpak apps all start through `flatpak run [--command=prog] app.id`: the app is the
    // command it runs (the process name), else its app id.
    if id == "flatpak" {
        id = exec
            .iter()
            .find_map(|t| t.strip_prefix("--command=").map(str::to_string))
            .or_else(|| exec.iter().skip_while(|t| *t != "run").skip(1).find(|t| !t.starts_with('-') && !t.starts_with('@')).cloned())?;
    }
    Some(DesktopEntry { name: name?, id, exec, path: path.to_path_buf() })
}

/// A loose AppImage: named after its file ("Obsidian-1.6.7-x86_64.AppImage" → "Obsidian").
fn appimage_entry(path: &Path) -> Option<DesktopEntry> {
    use std::os::unix::fs::PermissionsExt;
    let file = path.file_name()?.to_string_lossy().into_owned();
    if !file.to_lowercase().ends_with(".appimage") || std::fs::metadata(path).ok()?.permissions().mode() & 0o111 == 0 {
        return None;
    }
    let stem = &file[..file.len() - ".appimage".len()];
    let name = stem.split(['-', '_']).take_while(|p| !p.starts_with(|c: char| c.is_ascii_digit()) && !matches!(p.to_lowercase().as_str(), "x86" | "amd64" | "aarch64" | "arm64" | "x64")).collect::<Vec<_>>().join(" ");
    let name = if name.trim().is_empty() { stem.to_string() } else { name };
    Some(DesktopEntry { id: name.to_lowercase().replace(' ', "-"), name, exec: vec![path.to_string_lossy().into_owned()], path: path.to_path_buf() })
}

/// Installed apps from their desktop entries (read again at most every 30 s).
fn desktop_entries() -> Vec<DesktopEntry> {
    static CACHE: Mutex<Option<(Instant, Vec<DesktopEntry>)>> = Mutex::new(None);
    let mut g = CACHE.lock().unwrap();
    if let Some((at, list)) = g.as_ref() {
        if at.elapsed() < Duration::from_secs(30) {
            return list.clone();
        }
    }
    let list = read_desktop_entries();
    *g = Some((Instant::now(), list.clone()));
    list
}

fn read_desktop_entries() -> Vec<DesktopEntry> {
    // Desktop files in subfolders count too (Wine puts its programs in nested folders); a
    // file id ("org.app.desktop", "wine-Programs-App.desktop") found first wins, as menus do.
    fn walk(dir: &Path, rel: &str, depth: u32, seen: &mut std::collections::HashSet<String>, out: &mut Vec<DesktopEntry>) {
        let Ok(rd) = std::fs::read_dir(dir) else { return };
        for e in rd.flatten() {
            let p = e.path();
            let name = e.file_name().to_string_lossy().into_owned();
            if p.is_dir() {
                if depth < 4 {
                    walk(&p, &format!("{rel}{name}-"), depth + 1, seen, out);
                }
            } else if name.ends_with(".desktop") && seen.insert(format!("{rel}{name}")) {
                if let Some(entry) = parse_desktop(&p) {
                    out.push(entry);
                }
            }
        }
    }
    let mut out: Vec<DesktopEntry> = vec![];
    let mut seen = std::collections::HashSet::new();
    for d in desktop_dirs() {
        walk(&d, "", 0, &mut seen, &mut out);
    }
    for d in appimage_dirs() {
        let Ok(rd) = std::fs::read_dir(&d) else { continue };
        for e in rd.flatten() {
            if let Some(entry) = appimage_entry(&e.path()) {
                // Already in the menu (an AppImage tool added it): keep the menu entry.
                if !out.iter().any(|o| o.exec.first().is_some_and(|x| Path::new(x) == e.path()) || same(&o.name, &entry.name)) {
                    out.push(entry);
                }
            }
        }
    }
    // One line per app: entries that are the same app (same name and program) collapse.
    let mut unique: Vec<DesktopEntry> = vec![];
    for e in out {
        if !unique.iter().any(|u| same(&u.name, &e.name) && same(&u.id, &e.id)) {
            unique.push(e);
        }
    }
    unique.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    unique
}

fn same(a: &str, b: &str) -> bool {
    a.trim().eq_ignore_ascii_case(b.trim())
}

impl Native {
    fn running(&self) -> Vec<(AppRef, bool)> {
        let Some(a) = self.atspi.as_ref() else { return vec![] };
        let entries = desktop_entries();
        let mut out = vec![];
        let mut seen = std::collections::HashSet::new();
        for app in a.applications() {
            let Some(pid) = a.pid_of(&app.bus) else { continue };
            if pid == self.own_pid || !seen.insert(pid) {
                continue;
            }
            let id = exe_id(pid).unwrap_or_default();
            // The installed app's name ("Calculator"), else what the app calls itself.
            let name = entries.iter().find(|d| same(&d.id, &id)).map(|d| d.name.clone()).or_else(|| a.name(&app)).unwrap_or_else(|| id.clone());
            let has_window = self.x11.as_ref().is_some_and(|x| !x.windows_of(pid).is_empty()) || !a.children(&app).is_empty();
            out.push((AppRef { name, id, path: exe_path(pid), pid: Some(pid) }, has_window));
        }
        out
    }
}

// ------------------------------------------------------------------ tree

/// AT-SPI role name → our words.
fn map_role(role: &str, st: u64, ifaces: &[String]) -> (String, Option<String>, bool) {
    let editable = has(st, state::EDITABLE) && !has(st, state::READ_ONLY);
    let (r, sub): (&str, Option<&str>) = match role {
        "push button" | "button" => ("button", None),
        "toggle button" => ("button", Some("toggle button")),
        "check box" => ("check box", None),
        "radio button" => ("radio button", None),
        "entry" | "spin button" => ("text field", None),
        "password text" => ("text field", Some("secure text field")),
        // GTK 4 reports text views and entries as "text box".
        "text" | "text box" if has(st, state::MULTI_LINE) && editable => ("text area", None),
        "text" if has(st, state::MULTI_LINE) => ("text area", None),
        "text" | "text box" if editable => ("text field", None),
        "text box" => ("text", None),
        "text" | "label" | "static" | "caption" | "paragraph" | "heading" => ("text", None),
        "frame" | "window" => ("window", None),
        "dialog" | "alert" | "file chooser" => ("window", Some("dialog")),
        "panel" | "filler" | "viewport" | "section" | "form" | "grouping" | "block quote" | "unknown" | "redundant object" => ("group", None),
        "scroll pane" => ("scroll area", None),
        "menu bar" => ("menu bar", None),
        "menu" => ("menu", None),
        "menu item" => ("menu item", None),
        "check menu item" => ("menu item", Some("check menu item")),
        "radio menu item" => ("menu item", Some("radio menu item")),
        "tool bar" => ("toolbar", None),
        "page tab list" => ("tab group", None),
        "page tab" => ("tab", None),
        "list" | "list box" => ("list", None),
        "list item" => ("list item", None),
        "tree" | "tree table" => ("outline", None),
        "table" => ("table", None),
        "table row" => ("row", None),
        "table cell" => ("cell", None),
        "column header" | "table column header" => ("column header", None),
        "slider" => ("slider", None),
        "progress bar" => ("progress bar", None),
        "scroll bar" => ("scroll bar", None),
        "combo box" => ("combo box", None),
        "link" => ("link", None),
        "image" | "icon" => ("image", None),
        "document web" | "document frame" => ("web area", None),
        "status bar" => ("status bar", None),
        "separator" => ("group", None),
        other => {
            let t = other.to_string();
            return (t, None, ifaces.iter().any(|i| i.ends_with("EditableText")) && editable);
        }
    };
    (r.into(), sub.map(str::to_string), editable)
}

pub fn action_display(name: &str) -> Option<String> {
    let n = name.trim().to_lowercase();
    if matches!(n.as_str(), "click" | "press" | "activate" | "jump" | "") {
        return None;
    }
    Some(match n.as_str() {
        "toggle" => "Toggle".into(),
        "expand or contract" | "expand or collapse" => "Expand or Collapse".into(),
        "showmenu" | "show menu" | "menu" => "Show Menu".into(),
        _ => n.split([' ', '_', '-']).filter(|w| !w.is_empty()).map(|w| w[..1].to_uppercase() + &w[1..]).collect::<Vec<_>>().join(" "),
    })
}

struct ReadCtx<'a> {
    a: &'a Atspi,
    elements: Vec<El>,
    focused: Option<usize>,
    count: usize,
    deadline: Instant,
    cut: bool,
    has_web: bool,
    /// AT-SPI coordinate type, and what to add to get the coordinates the window uses.
    coord: u32,
    offset: (f64, f64),
}

fn read_node(ctx: &mut ReadCtx, el: &El, depth: usize, is_root: bool) -> Option<Node> {
    if ctx.count >= MAX_NODES || Instant::now() > ctx.deadline {
        ctx.cut = true;
        return None;
    }
    ctx.count += 1;
    let a = ctx.a;
    let role_name = a.role_name(el)?;
    let st = a.states(el);
    if !is_root && !has(st, state::SHOWING) && !has(st, state::VISIBLE) {
        return None;
    }
    let ifaces = a.interfaces(el);
    let has_if = |n: &str| ifaces.iter().any(|i| i.ends_with(n));
    let (role, subrole, editable) = map_role(&role_name, st, &ifaces);
    let mut node = Node { role, subrole, editable, ..Default::default() };
    node.is_window = node.role == "window";
    node.is_web_area = node.role == "web area";
    if node.is_web_area {
        ctx.has_web = true;
    }
    node.title = a.name(el);
    node.description = a.description(el).filter(|d| Some(d) != node.title.as_ref());
    node.secure = role_name == "password text";
    node.focused = has(st, state::FOCUSED);
    node.selected = has(st, state::SELECTED) && !matches!(node.role.as_str(), "text field" | "text area");
    node.expanded = has(st, state::EXPANDED);
    node.checked = has(st, state::CHECKED);
    node.disabled = !has(st, state::SENSITIVE) && !has(st, state::ENABLED) && !node.is_window;
    if let Some(id) = a.attributes(el).get("id").cloned() {
        node.identifier = Some(id);
    }
    if !node.secure {
        if has_if("Text") && matches!(node.role.as_str(), "text field" | "text area" | "text" | "combo box") {
            if let Some(t) = a.text(el) {
                if node.role == "text" {
                    if node.title.as_deref().map_or(true, |n| n.is_empty()) {
                        node.value = Some(t);
                    }
                } else {
                    node.value = Some(t);
                }
            }
        } else if has_if("Value") {
            node.value = a.value(el).map(|v| if v.fract() == 0.0 { format!("{}", v as i64) } else { format!("{v}") });
        }
    }
    if has_if("Action") {
        node.actions = a.actions(el).iter().filter_map(|n| action_display(n)).collect();
    }
    if let Some((x, y, w, h)) = a.extents_in(el, ctx.coord) {
        node.frame = Some((x as f64 + ctx.offset.0, y as f64 + ctx.offset.1, w as f64, h as f64));
    }
    node.identity = Some(el.key());
    let idx = ctx.elements.len();
    ctx.elements.push(el.clone());
    node.element = Some(idx);
    if node.focused {
        ctx.focused = Some(idx);
    }
    if depth < 40 && !node.secure {
        let kids = a.children(el);
        let total = kids.len();
        for k in kids {
            if let Some(c) = read_node(ctx, &k, depth + 1, false) {
                node.children.push(c);
            }
        }
        if total > 50 && node.children.len() < total {
            node.rows_note = Some(format!("({} of {total} rows shown; {} more rows hidden; scroll to see them)", node.children.len(), total - node.children.len()));
        }
    }
    Some(node)
}

impl Platform for Native {
    type Element = El;

    fn os(&self) -> &'static str {
        "linux"
    }

    fn permissions(&self) -> Permissions {
        // The accessibility bus is reachable: apps that expose AT-SPI can be read. (The
        // session-wide "assistive technologies on" flag only matters to toolkits that wait for
        // it; requestAccess switches it on.)
        Permissions { accessibility: self.atspi.is_some(), screen: self.x11.is_some() || self.wl.is_some() }
    }

    fn request_permissions(&self) -> Permissions {
        if let Some(a) = &self.atspi {
            switch_accessibility_on(a);
        }
        self.permissions()
    }

    fn list_apps(&self) -> Vec<AppEntry> {
        let active = self.frontmost_pid();
        let entries = desktop_entries();
        let mut out: Vec<AppEntry> = self
            .running()
            .into_iter()
            // Apps a person can work in: installed apps from the app menu, or anything with an
            // ordinary (X11) window. Background services that only register with
            // accessibility (the shell, input methods, notifiers, portals) are left out.
            .filter(|(app, _)| {
                entries.iter().any(|d| same(&d.id, &app.id)) || app.pid.is_some_and(|p| self.x11.as_ref().is_some_and(|x| !x.windows_of(p).is_empty()))
            })
            .map(|(app, has_window)| AppEntry { active: app.pid == active, running: true, has_window, app, last_used: None })
            .collect();
        for d in entries.into_iter().take(200) {
            // Listed already. Several menu apps may share one program (an office suite's
            // Writer and Calc): each stays listed under its own name.
            if out.iter().any(|e| same(&e.app.id, &d.id) && same(&e.app.name, &d.name)) {
                continue;
            }
            out.push(AppEntry {
                app: AppRef { name: d.name, id: d.id, path: d.path.to_string_lossy().into_owned(), pid: None },
                running: false,
                active: false,
                has_window: false,
                last_used: None,
            });
        }
        out
    }

    fn resolve(&self, query: &str) -> TurboResult<AppRef> {
        let running = self.running();
        let q = query.trim();
        if let Some((a, _)) = running.iter().find(|(a, _)| same(&a.id, q) || (q.starts_with('/') && a.path == q)) {
            return Ok(a.clone());
        }
        let by_name: Vec<&AppRef> = running.iter().map(|(a, _)| a).filter(|a| same(&a.name, q)).collect();
        if by_name.len() == 1 || by_name.iter().all(|a| a.id == by_name[0].id) && !by_name.is_empty() {
            return Ok(by_name[0].clone());
        }
        let entries = desktop_entries();
        if let Some(d) = entries.iter().find(|d| same(&d.id, q) || same(&d.name, q) || d.path.to_string_lossy() == q) {
            // Already running under its executable name: that one, never a second copy.
            if let Some((a, _)) = running.iter().find(|(a, _)| same(&a.id, &d.id)) {
                return Ok(a.clone());
            }
            return Ok(AppRef { name: d.name.clone(), id: d.id.clone(), path: d.path.to_string_lossy().into_owned(), pid: None });
        }
        if q.starts_with('/') && Path::new(q).is_file() {
            let id = Path::new(q).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            return Ok(AppRef { name: id.clone(), id, path: q.into(), pid: None });
        }
        Err(TurboError::new(ErrorCode::AppMissing, format!("No app named \"{}\" is running or installed. Use find_apps to see available apps.", turbo_core::protocol::clean(q, 80))))
    }

    fn launch(&self, app: &AppRef) -> TurboResult<AppRef> {
        if let Some((found, true)) = self.running().into_iter().find(|(a, _)| same(&a.id, &app.id)) {
            return Ok(found);
        }
        let cmd: Vec<String> = if app.path.ends_with(".desktop") {
            parse_desktop(Path::new(&app.path)).map(|d| d.exec).unwrap_or_default()
        } else if !app.path.is_empty() {
            vec![app.path.clone()]
        } else {
            vec![app.id.clone()]
        };
        let (program, args) = cmd.split_first().ok_or_else(|| TurboError::action(format!("{} has no command to launch.", app.name)))?;
        let mut c = std::process::Command::new(program);
        c.args(args).stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null());
        let mut child = c.spawn().map_err(|e| TurboError::action(format!("Could not launch {}: {e}", app.name)))?;
        let child_pid = child.id();
        std::thread::spawn(move || {
            let _ = child.wait();
        });
        turbo_core::log::info(format!("launching {} (pid {child_pid})", app.id));
        let until = Instant::now() + Duration::from_secs(10);
        while Instant::now() < until {
            std::thread::sleep(Duration::from_millis(250));
            if let Some((found, has_window)) = self.running().into_iter().find(|(a, _)| a.pid == Some(child_pid) || same(&a.id, &app.id)) {
                if has_window {
                    std::thread::sleep(Duration::from_millis(300));
                    return Ok(AppRef { name: if app.name.is_empty() { found.name } else { app.name.clone() }, ..found });
                }
            }
        }
        Err(TurboError::new(ErrorCode::NoWindow, format!("{} was started but showed no accessible window within 10 s; call observe_app again.{}", app.name, self.restart_hint(&app.name))))
    }

    fn is_running(&self, pid: u32) -> bool {
        Path::new(&format!("/proc/{pid}")).exists()
    }

    fn snapshot(&self, app: &AppRef, deadline: Instant) -> TurboResult<Snapshot<El>> {
        let a = self.a()?;
        let pid = app.pid.ok_or_else(|| TurboError::fault("snapshot without a pid"))?;
        let app_el = self.app_element(pid).ok_or_else(|| {
            TurboError::new(ErrorCode::NoWindow, format!("{} does not expose an accessibility tree yet (is it still starting, or not an accessible toolkit app?); observe again.{}", app.name, self.restart_hint(&app.name)))
        })?;
        let tops = a.children(&app_el);
        let lent = self.lent_dialogs(pid);
        let mut ctx = ReadCtx { a, elements: vec![], focused: None, count: 0, deadline, cut: false, has_web: false, coord: coord::SCREEN, offset: (0.0, 0.0) };
        // Key window: the active one, else the first showing top-level.
        let infos: Vec<(El, u64, String)> = tops.iter().map(|t| (t.clone(), a.states(t), a.role_name(t).unwrap_or_default())).collect();
        // A modal dialog blocks its window: it is what the user (and the agent) must answer.
        let key = infos
            .iter()
            .find(|(_, st, r)| matches!(r.as_str(), "dialog" | "alert" | "file chooser") && has(*st, state::MODAL) && has(*st, state::SHOWING))
            .or_else(|| infos.iter().find(|(_, st, _)| has(*st, state::ACTIVE)))
            .or_else(|| infos.iter().find(|(_, st, r)| has(*st, state::SHOWING) && r != "menu" && r != "window"))
            .or_else(|| infos.iter().find(|(_, st, _)| has(*st, state::SHOWING)))
            // A main window that does not (yet) say it is showing — some apps update that
            // state late — is still better than none.
            .or_else(|| infos.iter().find(|(_, _, r)| r == "frame"))
            .map(|(e, _, _)| e.clone());
        let mut roots = vec![];
        let mut window = None;
        // Wayland: element positions in the window's own coordinates; with the screen shared,
        // the screenshot is the whole desktop (where the window is on it is not known).
        let mut wl_frame = None;
        let mut notes = vec![];
        if let (true, Some(k)) = (self.native_wayland(pid), &key) {
            ctx.coord = coord::WINDOW;
            let size = a.extents_in(k, coord::WINDOW).map(|(_, _, w, h)| (w as f64, h as f64)).filter(|(w, h)| *w > 0.0 && *h > 0.0);
            let desktop = self.wl.as_ref().and_then(|wl| wl.ensure(Duration::from_millis(1500))).map(|l| l.desktop()).filter(|d| d.w > 0.0 && d.h > 0.0);
            wl_frame = match (desktop, size) {
                (Some(d), _) => {
                    // The screenshot is the whole screen: bring the app forward so it shows
                    // (and stays: keeps_front), unless the user is using the computer.
                    if self.frontmost_pid() != Some(pid) && self.idle_seconds() >= 1.5 && self.activate_wayland(pid) {
                        notes.push(format!("Note: {} was brought to the front (Alt+Tab) so the screenshot shows it.", app.name));
                        // Let the desktop repaint before the screenshot is taken.
                        std::thread::sleep(Duration::from_millis(300));
                    }
                    notes.push(format!("Note: on this Wayland desktop the screenshot shows the whole screen ({} is in it); x/y are screen pixels. Element positions are inside the app's window, so prefer element numbers.", app.name));
                    Some((WL_SHARED, d))
                }
                (None, Some((w, h))) => Some((WL_UNSHARED, Rect { x: 0.0, y: 0.0, w, h })),
                _ => None,
            };
        }
        // Dialogs another process opened for this app come first: they are what must be
        // answered (the app's own windows may not respond meanwhile).
        for (owner, w) in &lent {
            if let Some(node) = read_node(&mut ctx, w, 0, true) {
                let by = a.applications().into_iter().find(|x| a.pid_of(&x.bus) == Some(*owner)).and_then(|x| a.name(&x)).unwrap_or_else(|| "another app".into());
                notes.push(format!(
                    "Note: a dialog opened for {} by the system ({by}): \"{}\". It is listed first and takes input; answer it before using {}'s window.",
                    app.name,
                    node.title.clone().unwrap_or_default(),
                    app.name
                ));
                roots.push(node);
            }
        }
        if let Some(k) = &key {
            if let Some(node) = read_node(&mut ctx, k, 0, true) {
                // A dialog drawn inside the window (libadwaita) sits at the end of its tree:
                // say so up front.
                fn find_dialog(n: &Node) -> Option<String> {
                    n.children.iter().find_map(|c| {
                        if matches!(c.role.as_str(), "alert dialog" | "dialog" | "file chooser") {
                            Some(c.title.clone().unwrap_or_default())
                        } else {
                            find_dialog(c)
                        }
                    })
                }
                if let Some(t) = find_dialog(&node) {
                    notes.push(format!("Note: a dialog is open in {}'s window: \"{t}\". Answer it first; the window behind it does not take input meanwhile.", app.name));
                }
                let title = node.title.clone().unwrap_or_default();
                if let Some((kind, frame)) = wl_frame {
                    window = Some(WindowInfo { handle: kind | pid as u64, title, frame, pid });
                } else {
                    let xwin = self.x_window_for(pid, Some(&title));
                    let frame = xwin
                        .and_then(|w| self.x11.as_ref().and_then(|x| x.frame(w)))
                        .or_else(|| node.frame.map(|(x, y, w, h)| Rect { x, y, w, h }))
                        .filter(|r| r.w > 0.0 && r.h > 0.0);
                    if let Some(frame) = frame {
                        window = Some(WindowInfo { handle: xwin.unwrap_or(0) as u64, title, frame, pid });
                    }
                }
                roots.push(node);
            }
        }
        for (el, st, role) in &infos {
            if Some(el) == key.as_ref() {
                continue;
            }
            let showing = has(*st, state::SHOWING) || has(*st, state::VISIBLE);
            if !showing {
                continue;
            }
            if role == "window" || role == "menu" || role == "popup menu" {
                // Open menus and popups belong to the key window: read them in full.
                if let Some(n) = read_node(&mut ctx, el, 0, true) {
                    roots.push(n);
                }
            } else {
                let mut n = Node { role: "window".into(), title: a.name(el), is_window: true, summary_only: true, identity: Some(el.key()), actions: vec!["Raise".into()], ..Default::default() };
                n.element = Some(ctx.elements.len());
                ctx.elements.push(el.clone());
                roots.push(n);
            }
        }
        let selected_text = ctx.focused.and_then(|fi| {
            let el = &ctx.elements[fi];
            let (s, e) = a.selection(el)?;
            let text = a.text(el)?;
            let chars: Vec<char> = text.chars().collect();
            (s < e && (e as usize) <= chars.len()).then(|| chars[s as usize..e as usize].iter().collect())
        });
        Ok(Snapshot { roots, elements: ctx.elements, window, focused: ctx.focused, selected_text, has_web: ctx.has_web, page_loading: None, cut_short: ctx.cut, notes })
    }

    fn capture(&self, window: &WindowInfo) -> Option<RgbaImage> {
        if window.handle & WL_UNSHARED != 0 {
            return None;
        }
        if window.handle & WL_SHARED != 0 {
            // Only a stream that has just started waits: its first frame can take ~1.5 s.
            return self.link()?.image(Duration::from_millis(2500));
        }
        let x = self.x11.as_ref()?;
        let handle = if window.handle != 0 { window.handle as u32 } else { self.x_window_for(window.pid, Some(&window.title))? };
        x.capture(handle)
    }

    fn capture_note(&self, window: &WindowInfo) -> Option<String> {
        if window.handle & (WL_SHARED | WL_UNSHARED) == 0 {
            return None;
        }
        let name = self.app_name_of_pid(window.pid).unwrap_or_else(|| "the app".into());
        match &self.wl {
            Some(wl) => wl.note(),
            None => Some(format!(
                "Note: no screenshot: {name} is a Wayland window and this desktop offers no window sharing with remote input (XDG portal RemoteDesktop/ScreenCast). Element numbers and accessibility actions still work."
            )),
        }
    }

    fn live_frame(&self, window: &WindowInfo) -> Option<Rect> {
        if window.handle & WL_SHARED != 0 {
            return Some(self.link()?.desktop());
        }
        if window.handle & WL_UNSHARED != 0 {
            return None;
        }
        (window.handle != 0).then(|| self.x11.as_ref()?.frame(window.handle as u32)).flatten()
    }

    fn is_alive(&self, el: &El) -> bool {
        self.atspi.as_ref().is_some_and(|a| a.alive(el))
    }

    fn is_secure(&self, el: &El) -> bool {
        self.atspi.as_ref().and_then(|a| a.role_name(el)).is_some_and(|r| r == "password text")
    }

    fn element_text(&self, el: &El) -> Option<String> {
        let a = self.atspi.as_ref()?;
        a.text(el).or_else(|| a.name(el))
    }

    fn focused_secure(&self, pid: u32) -> Option<bool> {
        self.atspi.as_ref()?;
        Some(self.focused_in(pid).is_some_and(|el| self.is_secure(&el)))
    }

    fn frontmost_pid(&self) -> Option<u32> {
        if self.wayland {
            // Exactly one app must claim the front; two claims (a switch in progress) mean
            // "not known yet", never a guess (keys would go to the wrong window).
            match self.active_pids_atspi().as_slice() {
                [pid] => {
                    // A dialog another process opened for an app (a file chooser) stands for
                    // that app while it is in front.
                    if let Some(a) = self.atspi.as_ref() {
                        for (app, dialogs) in self.lent.lock().unwrap().iter() {
                            if dialogs.iter().any(|(owner, w)| owner == pid && has(a.states(w), state::ACTIVE)) {
                                return Some(*app);
                            }
                        }
                    }
                    return Some(*pid);
                }
                [] => {}
                _ => return None,
            }
        }
        self.x11.as_ref()?.active_pid()
    }

    fn activate(&self, pid: u32, window: Option<&WindowInfo>) -> bool {
        if self.native_wayland(pid) {
            return self.activate_wayland(pid);
        }
        let Some(x) = self.x11.as_ref() else { return false };
        let win = window.filter(|w| w.handle != 0 && w.pid == pid).map(|w| w.handle as u32).or_else(|| x.windows_of(pid).into_iter().next());
        let Some(win) = win else { return false };
        x.activate(win);
        let until = Instant::now() + Duration::from_millis(1200);
        while Instant::now() < until {
            if x.active_pid() == Some(pid) {
                std::thread::sleep(Duration::from_millis(80));
                return true;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        x.active_pid() == Some(pid)
    }

    fn keeps_front(&self, pid: u32) -> bool {
        self.native_wayland(pid)
    }

    fn activate_hint(&self, pid: u32, what: &str) -> Option<String> {
        if !self.native_wayland(pid) {
            return None;
        }
        let name = self.app_name_of_pid(pid).unwrap_or_else(|| "The app".into());
        Some(format!(
            "{name} could not be brought to the front for {what} (the desktop's Alt+Tab switcher did not reach it, or the screen is not shared with remote interaction), so nothing was sent. Element numbers with accessibility actions (click_at on an element, write_text into a field, fill_value, invoke_action, run_command) work without that; otherwise ask the user to switch to {name}."
        ))
    }

    fn app_name_of_pid(&self, pid: u32) -> Option<String> {
        if let Some(a) = &self.atspi {
            if let Some(app) = self.app_element(pid) {
                if let Some(n) = a.name(&app) {
                    return Some(n);
                }
            }
        }
        exe_id(pid)
    }

    fn idle_seconds(&self) -> f64 {
        if self.wayland {
            if let Some(idle) = self.compositor_idle() {
                return idle;
            }
        }
        self.input.idle_seconds()
    }

    fn last_input_on(&self, pid: u32) -> Option<Instant> {
        self.input.per_pid.lock().unwrap().get(&pid).copied()
    }

    fn screen_locked(&self) -> bool {
        // The login manager's flag (any systemd desktop), else the session's screen saver.
        if let Some(locked) = logind_locked() {
            return locked;
        }
        let Some(s) = &self.session else { return false };
        s.call_method(Some("org.freedesktop.ScreenSaver"), "/org/freedesktop/ScreenSaver", Some("org.freedesktop.ScreenSaver"), "GetActive", &())
            .ok()
            .and_then(|m| m.body().deserialize::<bool>().ok())
            .unwrap_or(false)
    }

    fn host_window(&self, agent: &AgentIdentity) -> Option<(u32, Rect, bool)> {
        let x = self.x11.as_ref()?;
        let mut pids: Vec<u32> = agent.ancestor_pids.clone();
        if let Some(h) = agent.host_pid {
            pids.push(h);
        }
        let active = x.active_pid();
        for pid in pids {
            if let Some(w) = x.windows_of(pid).into_iter().next() {
                return Some((pid, x.frame(w)?, active == Some(pid)));
            }
        }
        None
    }

    fn host_window_hidden(&self, agent: &AgentIdentity) -> bool {
        if !self.wayland {
            return false;
        }
        // A Wayland session where one of the agent's processes (its app, or the terminal it
        // runs in) has a window: one shown through accessibility, or an installed desktop app
        // (it has a desktop entry) — X11 sees neither.
        let entries = desktop_entries();
        agent.host_pid.into_iter().chain(agent.ancestor_pids.iter().copied()).any(|pid| {
            let shown = self.atspi.as_ref().zip(self.app_element(pid)).is_some_and(|(a, app)| !a.children(&app).is_empty());
            shown || exe_id(pid).is_some_and(|id| entries.iter().any(|d| same(&d.id, &id)))
        })
    }

    fn host_ids(&self, agent: &AgentIdentity) -> Vec<String> {
        self.host_window(agent).and_then(|(pid, _, _)| exe_id(pid)).into_iter().collect()
    }

    fn act(&self, ctx: &ActCtx, step: PStep<El>) -> TurboResult<Option<String>> {
        // Remember the other processes' modal windows now: one that appears after this
        // action opened for this app.
        {
            let lent: std::collections::HashSet<String> = self.lent.lock().unwrap().get(&ctx.pid).map(|v| v.iter().map(|(_, w)| w.key()).collect()).unwrap_or_default();
            // Dialogs already lent to it stay lent.
            let keys = self.foreign_modals(ctx.pid).into_iter().map(|(_, w)| w.key()).filter(|k| !lent.contains(k)).collect();
            self.modal_baseline.lock().unwrap().insert(ctx.pid, keys);
        }
        input::act(self, ctx, step)
    }

    fn menu_commands(&self, app: &AppRef, deadline: Instant) -> MenuRead {
        match (self.atspi.as_ref(), app.pid.and_then(|p| self.app_element(p))) {
            (Some(a), Some(el)) => menus::read(a, &el, deadline),
            _ => MenuRead::default(),
        }
    }

    fn menu_signature(&self, app: &AppRef) -> String {
        match (self.atspi.as_ref(), app.pid.and_then(|p| self.app_element(p))) {
            (Some(a), Some(el)) => menus::signature(a, &el, &app.path),
            _ => String::new(),
        }
    }

    fn locate_command(&self, app: &AppRef, path: &[String]) -> Option<Located> {
        let a = self.atspi.as_ref()?;
        let el = self.app_element(app.pid?)?;
        menus::locate(a, &el, path).map(|(_, l, _)| l)
    }

    fn window_handles(&self, pid: u32) -> Vec<u64> {
        let big = |r: Option<Rect>| r.map_or(true, |r| !turbo_core::events::incidental_window(r.w, r.h));
        let mut out: Vec<u64> = self
            .x11
            .as_ref()
            .map(|x| x.windows_of(pid).into_iter().filter(|w| big(x.frame(*w))).map(u64::from).collect())
            .unwrap_or_default();
        // Dialogs are top-level accessibles too (also on Wayland, where X11 sees nothing),
        // with those another process opened for the app (a system file chooser).
        if let (Some(a), Some(app)) = (self.atspi.as_ref(), self.app_element(pid)) {
            let lent: Vec<El> = self.lent_dialogs(pid).into_iter().map(|(_, w)| w).collect();
            for t in a.children(&app).into_iter().chain(lent) {
                if a.extents(&t).is_some_and(|(_, _, w, h)| turbo_core::events::incidental_window(w as f64, h as f64)) {
                    continue;
                }
                let mut h = std::collections::hash_map::DefaultHasher::new();
                std::hash::Hash::hash(&t.key(), &mut h);
                out.push(std::hash::Hasher::finish(&h) | (1 << 63));
            }
        }
        out
    }

    fn element_center(&self, pid: u32, el: &El) -> Option<(f64, f64)> {
        // None for a native Wayland window: its place on screen is unknown.
        self.element_point(pid, el)
    }

    fn pointer_glide(&self, _pid: u32, x: f64, y: f64, show: bool, speed: f64) -> Option<Duration> {
        // Screen coordinates on X11, desktop coordinates of the shared screen on Wayland —
        // the same space the pointer window (an XWayland window there) is placed in.
        self.pointer.glide(x, y, show, speed)
    }

    fn pointer_click(&self) {
        self.pointer.click();
    }

    fn pointer_hide(&self) {
        self.pointer.hide();
    }

    fn events(&self) -> Option<&EventLog> {
        Some(&self.events.log)
    }

    fn watch(&self, pid: u32) {
        if self.atspi.is_some() {
            self.events.watch(pid);
        }
    }
}

impl Native {
    /// The live menu item at `path`, for `runCommand`.
    pub(crate) fn command_element(&self, app: &AppRef, path: &[String]) -> Option<(El, Located, Option<i32>)> {
        menus::locate(self.atspi.as_ref()?, &self.app_element(app.pid?)?, path)
    }
}

/// Agent apps may start MCP servers (and so this helper) with a minimal environment: fill in
/// the desktop session's variables from where every session keeps them — the runtime
/// directory, its D-Bus and Wayland sockets, the X11 sockets and the X authority file. Only
/// variables that are missing are set; runs before any thread starts.
pub fn restore_session_env() {
    let set = |k: &str, v: String| {
        if std::env::var_os(k).is_none() {
            std::env::set_var(k, v);
        }
    };
    let Some(rt) = std::env::var("XDG_RUNTIME_DIR").ok().or_else(turbo_core::paths::runtime_dir) else { return };
    set("XDG_RUNTIME_DIR", rt.clone());
    let rt_path = Path::new(&rt);
    if rt_path.join("bus").exists() {
        set("DBUS_SESSION_BUS_ADDRESS", format!("unix:path={rt}/bus"));
    }
    let names: Vec<String> = std::fs::read_dir(rt_path).map(|d| d.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect()).unwrap_or_default();
    let mut wayland: Vec<&String> = names.iter().filter(|n| n.starts_with("wayland-") && !n.ends_with(".lock")).collect();
    wayland.sort();
    if let Some(w) = wayland.first() {
        set("WAYLAND_DISPLAY", (*w).clone());
        set("XDG_SESSION_TYPE", "wayland".into());
    }
    if std::env::var_os("DISPLAY").is_none() {
        let mut xs: Vec<u32> = std::fs::read_dir("/tmp/.X11-unix")
            .map(|d| d.flatten().filter_map(|e| e.file_name().to_string_lossy().strip_prefix('X').and_then(|n| n.parse().ok())).collect())
            .unwrap_or_default();
        xs.sort();
        if let Some(n) = xs.first() {
            std::env::set_var("DISPLAY", format!(":{n}"));
        }
    }
    if std::env::var_os("XAUTHORITY").is_none() {
        // XWayland's authority file in the runtime directory, else the classic one.
        let auth = names
            .iter()
            .find(|n| n.contains("Xwaylandauth") || n.starts_with("xauth_") || n == &".Xauthority")
            .map(|n| rt_path.join(n))
            .or_else(|| std::env::var("HOME").ok().map(|h| Path::new(&h).join(".Xauthority")).filter(|p| p.exists()));
        if let Some(a) = auth {
            std::env::set_var("XAUTHORITY", a);
        }
    }
}

/// Switch accessibility on for the session, as screen readers do: the bus's IsEnabled flag
/// and, where the desktop has it, the toolkit setting several apps (Firefox, Chromium-based
/// ones) check at startup before exposing their UI. Returns when it was off.
fn switch_accessibility_on(a: &Atspi) -> Option<std::time::SystemTime> {
    let mut changed = false;
    if !a.enabled() {
        a.enable();
        changed = true;
    }
    let key = ["org.gnome.desktop.interface", "toolkit-accessibility"];
    let current = std::process::Command::new("gsettings").arg("get").args(key).output().ok().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string());
    if current.as_deref() == Some("false") {
        let ok = std::process::Command::new("gsettings").arg("set").args(key).arg("true").status().is_ok_and(|s| s.success());
        if ok {
            turbo_core::log::info("accessibility: switched the desktop's toolkit accessibility on (apps started before need a restart)");
            changed = true;
        }
    }
    changed.then(std::time::SystemTime::now)
}

/// `LockedHint` of this login session (systemd-logind), if available.
fn logind_locked() -> Option<bool> {
    let bus = zbus::blocking::Connection::system().ok()?;
    let v = bus
        .call_method(Some("org.freedesktop.login1"), "/org/freedesktop/login1/session/auto", Some("org.freedesktop.DBus.Properties"), "Get", &("org.freedesktop.login1.Session", "LockedHint"))
        .ok()?
        .body()
        .deserialize::<zbus::zvariant::OwnedValue>()
        .ok()?;
    bool::try_from(v).ok()
}

// ------------------------------------------------------------------ socket

/// Accept connections on the Unix socket (mode 0600, in an owner-only directory).
pub fn listen(endpoint: &str, handle: impl Fn(std::os::unix::net::UnixStream, u64) + Send + Sync + 'static) -> std::io::Result<()> {
    let path = Path::new(endpoint);
    if path.exists() {
        if std::os::unix::net::UnixStream::connect(path).is_ok() {
            return Err(std::io::Error::new(std::io::ErrorKind::AddrInUse, "another helper is listening"));
        }
        std::fs::remove_file(path)?;
    }
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let listener = UnixListener::bind(path)?;
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    turbo_core::log::info(format!("listening on {endpoint}"));
    let handle = Arc::new(handle);
    let mut n = 0u64;
    for stream in listener.incoming() {
        let Ok(stream) = stream else { continue };
        if !same_user(&stream) {
            turbo_core::log::info("rejected a connection from another user");
            continue;
        }
        n += 1;
        let h = handle.clone();
        std::thread::spawn(move || h(stream, n));
    }
    Ok(())
}

fn same_user(stream: &std::os::unix::net::UnixStream) -> bool {
    use std::os::unix::io::AsRawFd;
    let mut cred = libc::ucred { pid: 0, uid: 0, gid: 0 };
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    let r = unsafe { libc::getsockopt(stream.as_raw_fd(), libc::SOL_SOCKET, libc::SO_PEERCRED, &mut cred as *mut _ as *mut _, &mut len) };
    r == 0 && cred.uid == unsafe { libc::getuid() }
}
