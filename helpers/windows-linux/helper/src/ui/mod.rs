//! The helper's UI (approval card, status overlay, live preview), run in child processes of
//! the helper itself and driven over their stdin / stdout. On Windows the approval card is
//! the system's own dialog.

pub mod theme;
pub mod panels;
#[cfg(windows)]
mod native;

/// Exit code of a window process that could not draw anything (no usable graphics).
pub const NO_GRAPHICS: i32 = 3;
/// How long a window may take to draw its first frame.
const FIRST_FRAME_WITHIN: Duration = Duration::from_secs(8);

use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{sync_channel, SyncSender, TrySendError};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::json;
use turbo_core::log;
use turbo_core::ui::{ApprovalRequest, Choice, OverlayState, PreviewUpdate, Ui};

/// `--ui <mode> [json]` entry point.
pub fn run(mode: &str, arg: Option<&str>) -> i32 {
    if !matches!(mode, "approval" | "overlay" | "preview") {
        eprintln!("unknown --ui mode {mode}");
        return 64;
    }
    if mode != "approval" {
        panels::start_reading_stdin();
    }
    // CUT_UI_DEBUG=1: the windowing and rendering libraries' own log on stderr.
    if std::env::var_os("CUT_UI_DEBUG").is_some() {
        struct Stderr;
        impl ::log::Log for Stderr {
            fn enabled(&self, _: &::log::Metadata) -> bool {
                true
            }
            fn log(&self, r: &::log::Record) {
                eprintln!("[{}] {}: {}", r.level(), r.target(), r.args());
            }
            fn flush(&self) {}
        }
        static LOGGER: Stderr = Stderr;
        let _ = ::log::set_logger(&LOGGER);
        ::log::set_max_level(::log::LevelFilter::Debug);
    }
    // Windows asks for approval with its own dialog (TaskDialog): native, and it needs no
    // graphics driver.
    #[cfg(windows)]
    if mode == "approval" {
        let payload = arg.and_then(|a| serde_json::from_str(a).ok()).unwrap_or_default();
        return match native::approval(&payload) {
            Some(choice) => {
                println!("{choice}");
                0
            }
            None => NO_GRAPHICS,
        };
    }
    // Watchdog: some graphics drivers hang instead of failing (VMs, remote sessions): a
    // window that draws nothing in time gives up.
    std::thread::spawn(|| {
        std::thread::sleep(FIRST_FRAME_WITHIN);
        if !panels::drawn() {
            eprintln!("ui: nothing drawn within {} s (no usable graphics)", FIRST_FRAME_WITHIN.as_secs());
            std::process::exit(NO_GRAPHICS);
        }
    });
    // OpenGL with a transparent window; on Windows machines without a transparent OpenGL
    // configuration (VMs, some ARM and remote sessions) an opaque window.
    #[cfg(windows)]
    let order = [true, false];
    #[cfg(not(windows))]
    let order = [true];
    let mut last = String::new();
    for transparent in order {
        panels::set_transparent(transparent);
        eprintln!("ui: starting {mode} (transparent: {transparent})");
        let r = match mode {
            "approval" => panels::run_approval(arg.unwrap_or("{}")),
            "overlay" => panels::run_overlay(),
            _ => panels::run_preview(),
        };
        match r {
            Ok(()) => return 0,
            Err(e) => {
                last = e.to_string();
                eprintln!("ui error ({last})");
            }
        }
    }
    eprintln!("ui error: the window could not start ({last})");
    NO_GRAPHICS
}

/// A window process and the queue its own writer thread feeds into its stdin: the helper
/// never blocks on a window that is slow to read (a full queue drops the line).
struct Proc {
    child: Child,
    lines: SyncSender<String>,
}

fn writer(mut stdin: ChildStdin) -> SyncSender<String> {
    let (tx, rx) = sync_channel::<String>(8);
    std::thread::spawn(move || {
        for line in rx {
            if writeln!(stdin, "{line}").and_then(|_| stdin.flush()).is_err() {
                break;
            }
        }
    });
    tx
}

pub struct ChildUi {
    overlay: Mutex<Option<Proc>>,
    preview: Mutex<Option<Proc>>,
    /// A window process exited with NO_GRAPHICS: not started again in this run.
    no_graphics: std::sync::atomic::AtomicBool,
    on_stop: Arc<dyn Fn() + Send + Sync>,
}

fn exe() -> std::path::PathBuf {
    std::env::current_exe().unwrap_or_else(|_| "computer-use-turbo-helper".into())
}

impl ChildUi {
    pub fn new(on_stop: Arc<dyn Fn() + Send + Sync>) -> Self {
        Self { overlay: Mutex::new(None), preview: Mutex::new(None), no_graphics: Default::default(), on_stop }
    }

    fn spawn(&self, mode: &str, watch_stop: bool) -> Option<Proc> {
        let mut child = Command::new(exe())
            .args(["--ui", mode])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| log::error(format!("ui: could not start the {mode} window: {e}")))
            .ok()?;
        let stdin = child.stdin.take()?;
        let stdout = child.stdout.take()?;
        if watch_stop {
            let on_stop = self.on_stop.clone();
            std::thread::spawn(move || {
                for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                    if line.trim() == "stop" {
                        on_stop();
                    }
                }
            });
        }
        Some(Proc { child, lines: writer(stdin) })
    }

    fn send(&self, slot: &Mutex<Option<Proc>>, mode: &str, watch: bool, line: String, create: bool) {
        let mut guard = slot.lock().unwrap();
        let exited = guard.as_mut().and_then(|p| p.child.try_wait().ok().flatten());
        if exited.is_some_and(|s| s.code() == Some(NO_GRAPHICS)) && !self.no_graphics.swap(true, std::sync::atomic::Ordering::SeqCst) {
            log::error(format!("ui: the {mode} window cannot draw here (no usable graphics); helper windows stay off for this run"));
        }
        let alive = guard.as_mut().is_some_and(|p| p.child.try_wait().ok().flatten().is_none());
        if !alive {
            if !create || self.no_graphics.load(std::sync::atomic::Ordering::SeqCst) {
                *guard = None;
                return;
            }
            *guard = self.spawn(mode, watch);
        }
        if let Some(p) = guard.as_mut() {
            if let Err(TrySendError::Disconnected(_)) = p.lines.try_send(line) {
                *guard = None;
            }
        }
    }
}

impl Ui for ChildUi {
    fn ask(&self, r: &ApprovalRequest) -> Choice {
        let payload = json!({"agent": r.agent, "appName": r.app_name, "appId": r.app_id, "appPath": r.app_path,
            "timeoutSecs": r.timeout_secs});
        let child = Command::new(exe())
            .args(["--ui", "approval", &payload.to_string()])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn();
        let Ok(mut child) = child else {
            log::error("ui: could not start the approval card");
            return Choice::Unavailable;
        };
        let stdout = child.stdout.take();
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let mut line = String::new();
            if let Some(out) = stdout {
                let _ = BufReader::new(out).read_line(&mut line);
            }
            let _ = tx.send(line);
        });
        let answer = rx.recv_timeout(Duration::from_secs(r.timeout_secs + 5)).unwrap_or_default();
        let _ = child.kill();
        let status = child.wait();
        // No answer and a failed exit: the card never showed (no usable graphics); the user did
        // not decline anything.
        if answer.trim().is_empty() && status.is_ok_and(|s| !s.success()) {
            log::error("ui: the approval card could not be shown");
            return Choice::Unavailable;
        }
        Choice::parse(&answer)
    }

    fn overlay(&self, state: OverlayState) {
        let (line, create) = match state {
            OverlayState::Active { agent, app } => (json!({"state": "active", "agent": agent, "app": app}), true),
            OverlayState::Stopped => (json!({"state": "stopped"}), false),
            OverlayState::Hidden => (json!({"state": "hidden"}), false),
        };
        self.send(&self.overlay, "overlay", true, line.to_string(), create);
    }

    fn preview(&self, update: PreviewUpdate) {
        match update {
            PreviewUpdate::Frame { jpeg, width, height, anchor, app } => {
                let anchor = anchor.map(|r| json!([r.x, r.y, r.w, r.h])).unwrap_or(serde_json::Value::Null);
                let line = json!({"cmd": "frame", "jpeg": turbo_core::b64::encode(&jpeg), "w": width, "h": height, "anchor": anchor, "app": app});
                self.send(&self.preview, "preview", false, line.to_string(), true);
            }
            PreviewUpdate::Hide => self.send(&self.preview, "preview", false, json!({"cmd": "hide"}).to_string(), false),
        }
    }
}

impl Drop for ChildUi {
    fn drop(&mut self) {
        for slot in [&self.overlay, &self.preview] {
            if let Some(mut p) = slot.lock().unwrap().take() {
                let _ = p.child.kill();
            }
        }
    }
}
