//! What an operating-system layer provides. The service owns the
//! protocol, safety and approvals; the platform only reads UI, captures windows and
//! delivers input.

use std::cell::RefCell;
use std::time::{Duration, Instant};

use image::RgbaImage;

use crate::agent::AgentIdentity;
use crate::errors::TurboResult;
use crate::events::{EventLog, Located, MenuRead};
use crate::keys::Chord;
use crate::steps::{Button, Caret, Direction, PasteFormat};
use crate::tree::Node;

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Rect {
    pub fn contains(&self, x: f64, y: f64) -> bool {
        x >= self.x && y >= self.y && x < self.x + self.w && y < self.y + self.h
    }
}

/// A resolved target app (`Resolved`). `id`: the bundle id equivalent —
/// the executable file name on Windows (`notepad.exe`), the executable name on Linux.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AppRef {
    pub name: String,
    pub id: String,
    pub path: String,
    pub pid: Option<u32>,
}

impl AppRef {
    pub fn key(&self) -> String {
        if self.id.is_empty() { self.path.to_lowercase() } else { crate::policy::normalize_id(&self.id) }
    }
}

#[derive(Clone, Debug)]
pub struct AppEntry {
    pub app: AppRef,
    pub running: bool,
    pub active: bool,
    pub has_window: bool,
    pub last_used: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct WindowInfo {
    /// Native handle: HWND on Windows, X11 window id on Linux.
    pub handle: u64,
    pub title: String,
    pub frame: Rect,
    pub pid: u32,
}

#[derive(Clone, Copy, Debug, Default)]
pub struct Permissions {
    pub accessibility: bool,
    pub screen: bool,
}

/// One read of an app: roots (key window and what is attached to it, other windows as
/// summary lines, open menus, the menu bar) plus the live elements nodes refer to.
pub struct Snapshot<E> {
    pub roots: Vec<Node>,
    pub elements: Vec<E>,
    pub window: Option<WindowInfo>,
    /// Index into `elements` of the focused element.
    pub focused: Option<usize>,
    pub selected_text: Option<String>,
    pub has_web: bool,
    /// "yes (63%)" / "no" when the window shows web content.
    pub page_loading: Option<String>,
    pub cut_short: bool,
    /// Notes for the agent about this read ("the window was restored from minimized").
    pub notes: Vec<String>,
}

pub enum ActTarget<E> {
    Element { index: usize, el: E },
    /// Global screen coordinates.
    Point { x: f64, y: f64 },
}

/// A step with its element numbers resolved to live elements and its coordinates mapped to
/// the screen.
pub enum PStep<E> {
    Click { target: ActTarget<E>, button: Button, times: u8 },
    Scroll { target: ActTarget<E>, direction: Direction, pages: f64 },
    Drag { from: (f64, f64), to: (f64, f64) },
    WriteText { text: String, el: Option<E> },
    SendKeys { chord: Chord, shown: String },
    FillValue { el: E, value: String },
    PickText { el: E, start: usize, len: usize, mode: Caret },
    InvokeAction { el: E, name: String },
    PasteText { text: String, format: PasteFormat },
    RunCommand { path: Vec<String> },
}

/// What a step may need from the service while it runs.
pub struct ActCtx<'a> {
    pub app: &'a AppRef,
    pub pid: u32,
    pub window: Option<&'a WindowInfo>,
    /// The target is the frontmost app right now.
    pub front: bool,
    /// The app draws its own UI: it is in front and clicks go with the real pointer.
    pub self_drawn: bool,
    /// Bring the target forward for this one step (waits ≤ 2 s for the user to be idle;
    /// `userActive` otherwise; handed back after the step). No-op when already in front.
    pub borrow_front: &'a dyn Fn(&str) -> TurboResult<()>,
    /// Wait (≤ 2 s) until the user is not using the mouse / keyboard before the real pointer
    /// is moved for this step (put back afterwards); `userActive` otherwise.
    pub need_idle: &'a dyn Fn(&str) -> TurboResult<()>,
    pub interrupted: &'a dyn Fn() -> bool,
    /// The target is still the front app (checked while real keys are being typed: keys
    /// always go to the front window, so typing stops the moment it is not the target).
    pub still_front: &'a dyn Fn() -> bool,
    pub notes: RefCell<Vec<String>>,
}

impl ActCtx<'_> {
    pub fn note(&self, n: impl Into<String>) {
        let n = n.into();
        let mut v = self.notes.borrow_mut();
        if !v.contains(&n) {
            v.push(n);
        }
    }
}

pub trait Platform: Send + Sync + 'static {
    type Element: Clone + Send + 'static;

    /// Section of `shared/policy.json`: "windows" or "linux".
    fn os(&self) -> &'static str;
    fn permissions(&self) -> Permissions;
    fn request_permissions(&self) -> Permissions;

    fn list_apps(&self) -> Vec<AppEntry>;
    fn resolve(&self, query: &str) -> TurboResult<AppRef>;
    /// Start the app without taking the front where the OS allows it; wait for a window.
    fn launch(&self, app: &AppRef) -> TurboResult<AppRef>;
    fn is_running(&self, pid: u32) -> bool;

    fn snapshot(&self, app: &AppRef, deadline: Instant) -> TurboResult<Snapshot<Self::Element>>;
    fn capture(&self, window: &WindowInfo) -> Option<RgbaImage>;
    /// The window's current frame (it may have moved since the observation).
    fn live_frame(&self, window: &WindowInfo) -> Option<Rect>;

    fn is_alive(&self, el: &Self::Element) -> bool;
    fn is_secure(&self, el: &Self::Element) -> bool;
    fn element_text(&self, el: &Self::Element) -> Option<String>;
    /// Whether the app's focused element is a password field (None = cannot tell).
    fn focused_secure(&self, pid: u32) -> Option<bool>;

    fn frontmost_pid(&self) -> Option<u32>;
    fn activate(&self, pid: u32, window: Option<&WindowInfo>) -> bool;
    /// Why `activate` cannot work for this app, said to the agent instead of the generic
    /// message (e.g. a display system that lets no app raise another app's window).
    fn activate_hint(&self, _pid: u32, _what: &str) -> Option<String> {
        None
    }
    /// Why the window has no screenshot right now, when the platform knows better than "it
    /// may be minimized" (e.g. screen sharing not approved yet).
    fn capture_note(&self, _window: &WindowInfo) -> Option<String> {
        None
    }
    /// A front taken for `pid` stays with it for the job instead of going back to the
    /// previous app (Wayland: the screenshot is the whole screen, so the agent must see it).
    fn keeps_front(&self, _pid: u32) -> bool {
        false
    }
    fn app_name_of_pid(&self, pid: u32) -> Option<String>;
    /// Seconds since the user's last keyboard / mouse input.
    fn idle_seconds(&self) -> f64;
    /// Latest user input aimed at `pid` (clicks into its windows, keys while it is in front).
    fn last_input_on(&self, pid: u32) -> Option<Instant>;
    fn screen_locked(&self) -> bool;

    /// The agent's host app: (pid, window frame, frontmost) of the nearest ancestor with a
    /// window.
    fn host_window(&self, agent: &AgentIdentity) -> Option<(u32, Rect, bool)>;
    /// App ids of the host (protected: the agent never controls itself).
    fn host_ids(&self, agent: &AgentIdentity) -> Vec<String>;
    /// The agent's app has a window, but the display system does not say where it is
    /// (Wayland): the live preview then docks under the status overlay.
    fn host_window_hidden(&self, _agent: &AgentIdentity) -> bool {
        false
    }

    fn act(&self, ctx: &ActCtx, step: PStep<Self::Element>) -> TurboResult<Option<String>>;

    /// The app's menu commands, read without opening a menu.
    fn menu_commands(&self, _app: &AppRef, _deadline: Instant) -> MenuRead {
        MenuRead::default()
    }
    /// Cheap change check for `menu_commands` (app build + top-level menus).
    fn menu_signature(&self, _app: &AppRef) -> String {
        String::new()
    }
    /// The live command at `path` (titles compared with `events::same_title`).
    fn locate_command(&self, _app: &AppRef, _path: &[String]) -> Option<Located> {
        None
    }
    /// The app's top-level windows and dialogs right now (native handles), for `newWindow`.
    fn window_handles(&self, _pid: u32) -> Vec<u64> {
        vec![]
    }
    /// Accessibility events of the apps being watched; None = not available.
    /// Centre of an element of app `pid` in the coordinates input uses (where the agent
    /// pointer points); None when its place on screen is not known.
    fn element_center(&self, _pid: u32, _el: &Self::Element) -> Option<(f64, f64)> {
        None
    }
    /// The agent pointer: glide to (x, y) for an action on `pid`; drawn only while
    /// `show`. Returns how long the glide takes (None: no pointer here, e.g. a window whose
    /// screen position the display system hides).
    fn pointer_glide(&self, _pid: u32, _x: f64, _y: f64, _show: bool, _speed: f64) -> Option<Duration> {
        None
    }
    /// The click feedback at the pointer's tip.
    fn pointer_click(&self) {}
    fn pointer_hide(&self) {}

    fn events(&self) -> Option<&EventLog> {
        None
    }
    /// Start delivering events of `pid` to `events()` (idempotent).
    fn watch(&self, _pid: u32) {}
}
