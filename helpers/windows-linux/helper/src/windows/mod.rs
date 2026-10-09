//! Windows platform layer: UI Automation for the UI tree and background actions, Win32 for
//! windows, capture and — only when needed — SendInput.

mod events;
pub mod input;
mod menus;
mod pointer;
mod sys;
mod uia;

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use image::RgbaImage;
use turbo_core::agent::AgentIdentity;
use turbo_core::errors::{ErrorCode, TurboError, TurboResult};
use turbo_core::events::{EventLog, Located, MenuRead};
use turbo_core::platform::{ActCtx, AppEntry, AppRef, PStep, Permissions, Platform, Rect, Snapshot, WindowInfo};
use turbo_core::tree::Node;
use uia::{El, Read, Uia};
use windows::Win32::Foundation::HWND;

pub struct Native {
    uia: Uia,
    pointer: pointer::Pointer,
    own_pid: u32,
    start_apps: Mutex<Option<(Instant, Vec<(String, String)>)>>,
    events: events::Events,
}

impl Native {
    pub fn new(on_esc: Arc<dyn Fn() + Send + Sync>) -> Self {
        unsafe {
            let _ = windows::Win32::UI::HiDpi::SetProcessDpiAwarenessContext(windows::Win32::UI::HiDpi::DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        }
        sys::start_hooks(on_esc);
        let uia = Uia::new().expect("UI Automation is not available");
        Self { uia, pointer: pointer::Pointer::new(), own_pid: std::process::id(), start_apps: Mutex::new(None), events: events::Events::new() }
    }

    /// Start menu apps (desktop and packaged): name and AppID, from `Get-StartApps`.
    fn start_apps(&self) -> Vec<(String, String)> {
        let mut g = self.start_apps.lock().unwrap();
        if let Some((t, v)) = g.as_ref() {
            if t.elapsed() < Duration::from_secs(120) {
                return v.clone();
            }
        }
        let out = std::process::Command::new("powershell.exe")
            .args(["-NoProfile", "-NonInteractive", "-Command", "Get-StartApps | ForEach-Object { \"$($_.Name)`t$($_.AppID)\" }"])
            .output()
            .ok()
            .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
            .unwrap_or_default();
        let list: Vec<(String, String)> = out
            .lines()
            .filter_map(|l| l.split_once('\t'))
            .map(|(n, id)| (n.trim().to_string(), id.trim().to_string()))
            .filter(|(n, id)| !n.is_empty() && !id.is_empty())
            .collect();
        *g = Some((Instant::now(), list.clone()));
        list
    }

    /// The app behind a top-level window: packaged apps live in a CoreWindow inside
    /// ApplicationFrameHost.
    fn app_of_window(&self, h: HWND) -> Option<AppRef> {
        let mut pid = sys::pid_of(h);
        let mut path = sys::exe_path(pid)?;
        if sys::class(h) == "ApplicationFrameWindow" {
            // A packaged app's frame: the app is the process of the hosted CoreWindow. The
            // host itself is never the app (no CoreWindow found: skip the window).
            let child = sys::windows_of_child_core(h)?;
            pid = sys::pid_of(child);
            path = sys::exe_path(pid)?;
        }
        let id = std::path::Path::new(&path).file_name()?.to_string_lossy().to_lowercase();
        let name = sys::product_name(&path).unwrap_or_else(|| sys::title(h));
        Some(AppRef { name, id, path, pid: Some(pid) })
    }

    fn running(&self) -> Vec<(AppRef, HWND)> {
        let mut out: Vec<(AppRef, HWND)> = vec![];
        for h in sys::app_windows() {
            if let Some(a) = self.app_of_window(h) {
                if a.pid == Some(self.own_pid) || out.iter().any(|(o, _)| o.pid == a.pid) {
                    continue;
                }
                out.push((a, h));
            }
        }
        out
    }

    fn main_window(&self, pid: u32) -> Option<HWND> {
        let fg = unsafe { windows::Win32::UI::WindowsAndMessaging::GetForegroundWindow() };
        if sys::pid_of(fg) == pid {
            return Some(fg);
        }
        self.running().into_iter().find(|(a, _)| a.pid == Some(pid)).map(|(_, h)| h).or_else(|| sys::windows_of(pid).into_iter().next())
    }
}

/// The executable name of a Start-menu entry: a path's file name, or a packaged app's
/// executable from its manifest.
fn start_app_exe(id: &str) -> Option<String> {
    std::path::Path::new(id)
        .file_name()
        .map(|f| f.to_string_lossy().to_lowercase())
        .filter(|f| f.ends_with(".exe"))
        .or_else(|| sys::packaged_exe(id))
}

fn same(a: &str, b: &str) -> bool {
    let n = |s: &str| turbo_core::policy::normalize_id(s);
    n(a) == n(b)
}

impl Platform for Native {
    type Element = El;

    fn os(&self) -> &'static str {
        "windows"
    }

    fn permissions(&self) -> Permissions {
        // UI Automation and window capture need no grant on Windows.
        Permissions { accessibility: true, screen: true }
    }

    fn request_permissions(&self) -> Permissions {
        self.permissions()
    }

    fn list_apps(&self) -> Vec<AppEntry> {
        let fg = sys::foreground_pid();
        let mut out: Vec<AppEntry> = self
            .running()
            .into_iter()
            .map(|(a, _)| AppEntry { active: a.pid == fg, running: true, has_window: true, app: a, last_used: None })
            .collect();
        for (name, id) in self.start_apps().into_iter().take(150) {
            if out.iter().any(|e| e.app.name.eq_ignore_ascii_case(&name)) {
                continue;
            }
            let exe = start_app_exe(&id);
            out.push(AppEntry {
                app: AppRef { name, id: exe.unwrap_or_else(|| id.clone()), path: id, pid: None },
                running: false,
                active: false,
                has_window: false,
                last_used: None,
            });
        }
        out
    }

    fn resolve(&self, query: &str) -> TurboResult<AppRef> {
        let q = query.trim();
        let running = self.running();
        if let Some((a, _)) = running.iter().find(|(a, _)| same(&a.id, q) || a.path.eq_ignore_ascii_case(q)) {
            return Ok(a.clone());
        }
        if let Some((a, _)) = running.iter().find(|(a, h)| a.name.eq_ignore_ascii_case(q) || sys::title(*h).eq_ignore_ascii_case(q)) {
            return Ok(a.clone());
        }
        if let Some((name, id)) = self.start_apps().into_iter().find(|(n, id)| n.eq_ignore_ascii_case(q) || id.eq_ignore_ascii_case(q)) {
            let exe = start_app_exe(&id);
            return Ok(AppRef { name, id: exe.unwrap_or_else(|| id.clone()), path: id, pid: None });
        }
        if std::path::Path::new(q).is_file() {
            let id = std::path::Path::new(q).file_name().map(|f| f.to_string_lossy().to_lowercase()).unwrap_or_default();
            return Ok(AppRef { name: sys::product_name(q).unwrap_or_else(|| id.clone()), id, path: q.into(), pid: None });
        }
        Err(TurboError::new(ErrorCode::AppMissing, format!("No app named \"{}\" is running or installed. Use find_apps to see available apps.", turbo_core::protocol::clean(q, 80))))
    }

    fn launch(&self, app: &AppRef) -> TurboResult<AppRef> {
        let before: Vec<u32> = self.running().iter().filter_map(|(a, _)| a.pid).collect();
        let mut child_pid = None;
        if std::path::Path::new(&app.path).is_file() {
            let child = std::process::Command::new(&app.path).spawn().map_err(|e| TurboError::action(format!("Could not launch {}: {e}", app.name)))?;
            child_pid = Some(child.id());
        } else {
            std::process::Command::new("explorer.exe")
                .arg(format!("shell:AppsFolder\\{}", app.path))
                .spawn()
                .map_err(|e| TurboError::action(format!("Could not launch {}: {e}", app.name)))?;
        }
        turbo_core::log::info(format!("launching {}", app.id));
        let until = Instant::now() + Duration::from_secs(12);
        while Instant::now() < until {
            std::thread::sleep(Duration::from_millis(300));
            let found = self.running().into_iter().map(|(a, _)| a).find(|a| {
                a.pid == child_pid || (!before.contains(&a.pid.unwrap_or(0)) && (same(&a.id, &app.id) || a.name.eq_ignore_ascii_case(&app.name)))
            });
            if let Some(a) = found {
                std::thread::sleep(Duration::from_millis(300));
                return Ok(a);
            }
        }
        Err(TurboError::new(ErrorCode::NoWindow, format!("{} was started but showed no window within 12 s; call observe_app again.", app.name)))
    }

    fn is_running(&self, pid: u32) -> bool {
        sys::exe_path(pid).is_some()
    }

    fn snapshot(&self, app: &AppRef, deadline: Instant) -> TurboResult<Snapshot<El>> {
        let pid = app.pid.ok_or_else(|| TurboError::fault("snapshot without a pid"))?;
        let main = self.main_window(pid).ok_or_else(|| TurboError::new(ErrorCode::NoWindow, format!("{} has no window.", app.name)))?;
        let mut notes = vec![];
        // A minimized window has nothing to read or show (Store apps are even suspended):
        // restore it without activating it, so the user's focus stays where it is.
        if sys::restore_quietly(main) {
            notes.push(format!("Note: {}'s window was minimized; it was restored without taking the focus.", app.name));
        }
        let mut r = Read { elements: vec![], focused: None, count: 0, cut: false, has_web: false, deadline, focused_id: None };
        let mut roots: Vec<Node> = vec![];
        if let Some(n) = self.uia.read_window(main, &mut r) {
            roots.push(n);
        }
        // Owned popups / dialogs of the app on screen are part of the key window; other
        // top-level windows are one summary line each.
        for h in sys::windows_of(pid) {
            if h == main {
                continue;
            }
            let owned = sys::owner(h).is_some();
            if owned {
                if let Some(n) = self.uia.read_window(h, &mut r) {
                    roots.push(n);
                }
            } else if let Some(el) = self.uia.from_window(h) {
                let mut n = Node { role: "window".into(), title: Some(sys::title(h)).filter(|t| !t.is_empty()), is_window: true, summary_only: true, actions: vec!["Raise".into()], ..Default::default() };
                n.identity = uia::runtime_id(&el.0);
                n.element = Some(r.elements.len());
                r.elements.push(el);
                roots.push(n);
            }
        }
        let frame = sys::frame(main);
        let window = frame.map(|f| WindowInfo { handle: sys::handle_of(main), title: sys::title(main), frame: f, pid });
        let selected_text = r.focused.and_then(|i| r.elements.get(i)).and_then(|e| e.selected_text());
        Ok(Snapshot { roots, elements: r.elements, window, focused: r.focused, selected_text, has_web: r.has_web, page_loading: None, cut_short: r.cut, notes })
    }

    fn capture(&self, window: &WindowInfo) -> Option<RgbaImage> {
        let h = sys::hwnd(window.handle);
        sys::is_window(h).then(|| sys::capture(h)).flatten()
    }

    fn live_frame(&self, window: &WindowInfo) -> Option<Rect> {
        sys::frame(sys::hwnd(window.handle))
    }

    fn is_alive(&self, el: &El) -> bool {
        el.alive()
    }

    fn is_secure(&self, el: &El) -> bool {
        el.is_password()
    }

    fn element_text(&self, el: &El) -> Option<String> {
        el.text()
    }

    fn focused_secure(&self, pid: u32) -> Option<bool> {
        // Only the app in front has a keyboard focus Windows reports; for a background app the
        // check runs again right before keys are sent (after it was brought forward).
        Some(self.uia.focused().filter(|f| f.pid() == Some(pid)).is_some_and(|f| f.is_password()))
    }

    fn frontmost_pid(&self) -> Option<u32> {
        let pid = sys::foreground_pid()?;
        // Packaged apps: the frame host stands for the app inside it.
        let fg = unsafe { windows::Win32::UI::WindowsAndMessaging::GetForegroundWindow() };
        Some(self.app_of_window(fg).and_then(|a| a.pid).unwrap_or(pid))
    }

    fn activate(&self, pid: u32, window: Option<&WindowInfo>) -> bool {
        let h = window.filter(|w| w.pid == pid).map(|w| sys::hwnd(w.handle)).filter(|h| sys::is_window(*h)).or_else(|| self.main_window(pid));
        let Some(h) = h else { return false };
        sys::activate(h);
        let until = Instant::now() + Duration::from_millis(1000);
        while Instant::now() < until {
            // In front, and still in front a moment later (the switch has settled).
            if self.frontmost_pid() == Some(pid) && {
                std::thread::sleep(Duration::from_millis(80));
                self.frontmost_pid() == Some(pid)
            } {
                return true;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        false
    }

    fn app_name_of_pid(&self, pid: u32) -> Option<String> {
        let path = sys::exe_path(pid)?;
        sys::product_name(&path).or_else(|| std::path::Path::new(&path).file_stem().map(|s| s.to_string_lossy().into_owned()))
    }

    fn idle_seconds(&self) -> f64 {
        sys::idle_seconds()
    }

    fn last_input_on(&self, pid: u32) -> Option<Instant> {
        sys::last_input_on(pid)
    }

    fn screen_locked(&self) -> bool {
        sys::screen_locked()
    }

    fn host_window(&self, agent: &AgentIdentity) -> Option<(u32, Rect, bool)> {
        let mut pids = agent.ancestor_pids.clone();
        if let Some(h) = agent.host_pid {
            pids.push(h);
        }
        let fg = sys::foreground_pid();
        for pid in pids {
            if let Some((_, h)) = self.running().into_iter().find(|(a, _)| a.pid == Some(pid)) {
                return Some((pid, sys::frame(h)?, fg == Some(pid)));
            }
        }
        None
    }

    fn host_ids(&self, agent: &AgentIdentity) -> Vec<String> {
        self.host_window(agent).and_then(|(pid, _, _)| sys::exe_id(pid)).into_iter().collect()
    }

    fn act(&self, ctx: &ActCtx, step: PStep<El>) -> TurboResult<Option<String>> {
        input::act(self, ctx, step)
    }

    fn menu_commands(&self, app: &AppRef, deadline: Instant) -> MenuRead {
        app.pid.and_then(|p| self.main_window(p)).map(|h| menus::read(h, deadline)).unwrap_or_default()
    }

    fn menu_signature(&self, app: &AppRef) -> String {
        app.pid.and_then(|p| self.main_window(p)).map(|h| menus::signature(h, &app.path)).unwrap_or_default()
    }

    fn locate_command(&self, app: &AppRef, path: &[String]) -> Option<Located> {
        menus::locate(self.main_window(app.pid?)?, path).map(|(_, l)| l)
    }

    fn window_handles(&self, pid: u32) -> Vec<u64> {
        sys::windows_of(pid)
            .into_iter()
            .filter(|h| sys::frame(*h).map_or(true, |r| !turbo_core::events::incidental_window(r.w, r.h)))
            .map(sys::handle_of)
            .collect()
    }

    fn element_center(&self, _pid: u32, el: &El) -> Option<(f64, f64)> {
        el.center()
    }

    fn pointer_glide(&self, _pid: u32, x: f64, y: f64, show: bool, speed: f64) -> Option<Duration> {
        Some(self.pointer.glide(x, y, show, speed))
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
        self.events.watch(pid);
    }
}

impl Native {
    /// Run the menu command at `path`: WM_COMMAND to the app's window.
    pub(crate) fn run_command(&self, app: &AppRef, path: &[String]) -> TurboResult<String> {
        let shown = turbo_core::events::display_path(path);
        let window = app.pid.and_then(|p| self.main_window(p)).ok_or_else(|| TurboError::new(ErrorCode::NoWindow, format!("{} has no window.", app.name)))?;
        let (id, found) = menus::locate(window, path)
            .ok_or_else(|| TurboError::bad(format!("{} has no menu command {shown} right now; call find_command to see the current commands.", app.name)))?;
        if !found.enabled {
            return Err(TurboError::action(format!(
                "The command {} is unavailable (greyed out) in {} right now: it may need a selection or an open document, or a dialog of the app is open. Nothing was pressed.",
                turbo_core::events::display_path(&found.path),
                app.name
            )));
        }
        if !menus::run(window, id) {
            return Err(TurboError::action(format!("Sending the menu command {shown} to {} failed.", app.name)));
        }
        Ok(format!("Ran the menu command {} (sent to its window); {} stayed in the background.", turbo_core::events::display_path(&found.path), app.name))
    }
}

// ------------------------------------------------------------------ named pipe

/// Accept connections on the per-user named pipe (clients must be in the same session).
pub fn listen(name: &str, handle: impl Fn(std::fs::File, u64) + Send + Sync + 'static) -> std::io::Result<()> {
    use std::os::windows::io::FromRawHandle;
    use windows::core::PCWSTR;
    use windows::Win32::Storage::FileSystem::PIPE_ACCESS_DUPLEX;
    use windows::Win32::System::Pipes::{
        ConnectNamedPipe, CreateNamedPipeW, GetNamedPipeClientProcessId, PIPE_READMODE_BYTE, PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_BYTE, PIPE_UNLIMITED_INSTANCES,
        PIPE_WAIT,
    };
    use windows::Win32::System::RemoteDesktop::ProcessIdToSessionId;

    let wide: Vec<u16> = name.encode_utf16().chain(Some(0)).collect();
    let handle = Arc::new(handle);
    let mut own_session = 0u32;
    unsafe {
        let _ = ProcessIdToSessionId(std::process::id(), &mut own_session);
    }
    turbo_core::log::info(format!("listening on {name}"));
    let mut n = 0u64;
    loop {
        let pipe = unsafe {
            CreateNamedPipeW(
                PCWSTR(wide.as_ptr()),
                PIPE_ACCESS_DUPLEX,
                // Local clients only: the pipe is never reachable over the network.
                PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                PIPE_UNLIMITED_INSTANCES,
                1 << 20,
                1 << 20,
                0,
                None,
            )
        };
        if pipe.is_invalid() {
            return Err(std::io::Error::last_os_error());
        }
        let connected = unsafe { ConnectNamedPipe(pipe, None) };
        if connected.is_err() && std::io::Error::last_os_error().raw_os_error() != Some(535) {
            unsafe {
                let _ = windows::Win32::Foundation::CloseHandle(pipe);
            }
            continue;
        }
        let mut client = 0u32;
        let mut session = u32::MAX;
        unsafe {
            let _ = GetNamedPipeClientProcessId(pipe, &mut client);
            let _ = ProcessIdToSessionId(client, &mut session);
        }
        let file = unsafe { std::fs::File::from_raw_handle(pipe.0 as _) };
        if session != own_session {
            turbo_core::log::info("rejected a connection from another session");
            drop(file);
            continue;
        }
        n += 1;
        let h = handle.clone();
        std::thread::spawn(move || {
            uia::com_init();
            h(file, n)
        });
    }
}
