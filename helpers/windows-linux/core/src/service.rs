//! The request pipeline: `hello`, the ungated requests, and for
//! `observeApp` / `act` the safety steps in order — Stop, screen lock, permissions, policy,
//! take-back, password-manager confirmation — then the observation or the step. Platform-neutral: the OS layer
//! only reads UI, captures and delivers input.

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::{json, Map, Value};

use crate::agent::AgentRegistry;
use crate::errors::{ErrorCode, TurboError, TurboResult};
use crate::events::{self, WaitCondition};
use crate::image_util::{self, Geometry};
use crate::keys;
use crate::log;
use crate::paths::Paths;
use crate::platform::{ActCtx, ActTarget, AppRef, PStep, Platform, Snapshot, WindowInfo};
use crate::policy::{Decision, Evaluation, Risk, SafetyLists, SafetyPolicy};
use crate::protocol::{self, Envelope, Incoming, RequestType, RpcError, API_VERSION, HELPER_VERSION};
use crate::session::{AppState, Session};
use crate::steps::{find_text, Step, Target};
use crate::texts;
use crate::tree::{self, Observation};
use crate::ui::{ApprovalRequest, Choice, OverlayState, PreviewUpdate, Ui};

const OVERLAY_IDLE: Duration = Duration::from_secs(60);
const PREVIEW_IDLE: Duration = Duration::from_secs(30 * 60);
const SESSION_IDLE: Duration = Duration::from_secs(4 * 3600);
const SETTLE: Duration = Duration::from_millis(700);
const QUIET_SECONDS: f64 = 1.0;
const MAX_IDLE_WAIT: Duration = Duration::from_secs(2);
const TAKE_BACK: Duration = Duration::from_millis(1500);
const BORROW_HOLD: Duration = Duration::from_millis(400);

#[derive(Clone, Copy, Debug)]
pub struct Settings {
    pub borrow_front: bool,
    pub preview_enabled: bool,
    /// The agent pointer (`"pointer": {"enabled": true, "speed": 1.0}`).
    pub pointer_enabled: bool,
    pub pointer_speed: f64,
}

impl Settings {
    pub fn load(path: &std::path::Path) -> Self {
        let v: Value = std::fs::read_to_string(path).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or(Value::Null);
        Self {
            borrow_front: v.pointer("/focus/borrowFront").and_then(Value::as_bool).unwrap_or(true),
            preview_enabled: v.pointer("/preview/enabled").and_then(Value::as_bool).unwrap_or(true),
            pointer_enabled: v.pointer("/pointer/enabled").and_then(Value::as_bool).unwrap_or(true),
            pointer_speed: v.pointer("/pointer/speed").and_then(Value::as_f64).unwrap_or(1.0).clamp(0.25, 4.0),
        }
    }
}

#[derive(Clone)]
struct PreviewTarget {
    window: WindowInfo,
    app: String,
}

pub struct Service<P: Platform> {
    pub platform: Arc<P>,
    ui: Arc<dyn Ui>,
    pub paths: Paths,
    sessions: Mutex<HashMap<String, Session<P::Element>>>,
    stopped: Mutex<HashSet<String>>,
    pub agents: AgentRegistry,
    work: Mutex<()>,
    lists: SafetyLists,
    self_drawn: Mutex<HashMap<String, bool>>,
    preview_target: Mutex<Option<PreviewTarget>>,
    preview_forced: Mutex<Option<bool>>,
    last_gated: Mutex<Option<Instant>>,
    overlay_shown: AtomicBool,
}

/// One connection: frames in, frames out, `hello` first.
pub fn serve<P: Platform, S: Read + Write>(service: &Service<P>, mut stream: S, label: &str) {
    let mut hello = false;
    loop {
        let body = match protocol::read_frame(&mut stream) {
            Ok(Some(b)) => b,
            Ok(None) => break,
            Err(e) => {
                log::info(format!("{label}: closed ({e})"));
                break;
            }
        };
        let reply = match protocol::parse_message(&body) {
            Incoming::Notification => continue,
            Incoming::Invalid { id, error } => protocol::failure(id, &error),
            Incoming::Request { id, method, params } => {
                let started = Instant::now();
                let result = service.handle(&method, params.as_ref(), &mut hello);
                let what = if method == "request" {
                    Envelope::parse(params.as_ref()).map(|e| e.log_label()).unwrap_or_else(|_| "request".into())
                } else {
                    method.clone()
                };
                match result {
                    Ok(v) => {
                        log::info(format!("{label}: {what} → ok ({} ms)", started.elapsed().as_millis()));
                        protocol::success(id, v)
                    }
                    Err(e) => {
                        log::info(format!("{label}: {what} → {} ({} ms)", e.name, started.elapsed().as_millis()));
                        protocol::failure(json!(id), &e)
                    }
                }
            }
        };
        let bytes = serde_json::to_vec(&reply).unwrap_or_default();
        if protocol::write_frame(&mut stream, &bytes).is_err() {
            break;
        }
    }
}

impl<P: Platform> Service<P> {
    pub fn new(platform: Arc<P>, ui: Arc<dyn Ui>, paths: Paths) -> Arc<Self> {
        let lists = SafetyLists::load(platform.os());
        let profiles = std::fs::read_to_string(paths.profiles())
            .ok()
            .and_then(|t| serde_json::from_str::<Value>(&t).ok())
            .and_then(|v| v.get("apps").and_then(Value::as_object).cloned())
            .map(|apps| apps.iter().filter_map(|(k, v)| v.get("selfDrawn").and_then(Value::as_bool).map(|b| (k.clone(), b))).collect())
            .unwrap_or_default();
        let s = Arc::new(Self {
            platform,
            ui,
            paths,
            sessions: Mutex::new(HashMap::new()),
            stopped: Mutex::new(HashSet::new()),
            agents: AgentRegistry::new(),
            work: Mutex::new(()),
            lists,
            self_drawn: Mutex::new(profiles),
            preview_target: Mutex::new(None),
            preview_forced: Mutex::new(None),
            last_gated: Mutex::new(None),
            overlay_shown: AtomicBool::new(false),
        });
        Self::start_background(&s);
        s
    }

    /// Overlay idle hide, the live preview frames, screenshot and session sweeps.
    fn start_background(this: &Arc<Self>) {
        let me = Arc::downgrade(this);
        std::thread::Builder::new()
            .name("turbo-background".into())
            .spawn(move || {
                let mut tick = 0u64;
                loop {
                    std::thread::sleep(Duration::from_millis(250));
                    let Some(s) = me.upgrade() else { break };
                    tick += 1;
                    s.preview_tick();
                    if tick % 4 == 0 {
                        let idle = s.last_gated.lock().unwrap().map_or(true, |t| t.elapsed() > OVERLAY_IDLE);
                        if idle && s.overlay_shown.swap(false, Ordering::SeqCst) {
                            s.ui.overlay(OverlayState::Hidden);
                            s.platform.pointer_hide();
                        }
                    }
                    if tick % 1200 == 0 {
                        image_util::sweep(&s.paths.shots, 600);
                        let mut sessions = s.sessions.lock().unwrap();
                        sessions.retain(|_, sess| sess.last_touch.elapsed() < SESSION_IDLE);
                    }
                }
            })
            .ok();
    }

    fn settings(&self) -> Settings {
        Settings::load(&self.paths.settings())
    }

    fn preview_tick(&self) {
        let enabled = self.preview_forced.lock().unwrap().unwrap_or_else(|| self.settings().preview_enabled);
        let active = self.last_gated.lock().unwrap().is_some_and(|t| t.elapsed() < PREVIEW_IDLE);
        let target = self.preview_target.lock().unwrap().clone();
        let Some(target) = target.filter(|_| enabled && active) else { return };
        if self.platform.screen_locked() {
            return;
        }
        let Some(img) = self.platform.capture(&target.window) else { return };
        let (w, h) = img.dimensions();
        if w == 0 || h == 0 {
            return;
        }
        let scale = (480.0 / w as f64).min(1.0);
        let (tw, th) = (((w as f64) * scale) as u32, ((h as f64) * scale) as u32);
        let small = image::imageops::resize(&img, tw.max(1), th.max(1), image::imageops::FilterType::Triangle);
        let mut jpeg = vec![];
        let rgb = image::DynamicImage::ImageRgba8(small).to_rgb8();
        if image::codecs::jpeg::JpegEncoder::new_with_quality(&mut jpeg, 70).encode_image(&rgb).is_err() {
            return;
        }
        // The preview belongs to the agent: beside its window; docked under the status overlay
        // when the agent has a window the display system does not place (Wayland); none for an
        // agent without a window (headless or unknown host).
        let agent = self.agents.current();
        let anchor = match self.platform.host_window(&agent) {
            Some((_, r, _)) => Some(r),
            None if self.platform.host_window_hidden(&agent) => None,
            None => {
                self.ui.preview(PreviewUpdate::Hide);
                return;
            }
        };
        self.ui.preview(PreviewUpdate::Frame { jpeg, width: tw, height: th, anchor, app: target.app });
    }

    /// The user pressed Stop / Esc: every session stops until it ends; the agent is told to
    /// stop and ask the user, and a new session starts fresh.
    pub fn user_stop(&self) {
        let ids: Vec<String> = self.sessions.lock().map(|s| s.keys().cloned().collect()).unwrap_or_default();
        self.stopped.lock().unwrap().extend(ids);
        self.ui.overlay(OverlayState::Stopped);
        self.ui.preview(PreviewUpdate::Hide);
        self.platform.pointer_hide();
        *self.preview_target.lock().unwrap() = None;
        log::info("Stop: the user stopped Computer Use");
    }

    pub fn active_recently(&self) -> bool {
        self.last_gated.lock().unwrap().is_some_and(|t| t.elapsed() < OVERLAY_IDLE)
    }

    fn is_stopped(&self, session: &str) -> bool {
        self.stopped.lock().unwrap().contains(session)
    }

    pub fn handle(&self, method: &str, params: Option<&Value>, hello: &mut bool) -> Result<Value, RpcError> {
        match method {
            "hello" => {
                let want = params.and_then(|p| p.get("clientApiVersion")).and_then(Value::as_str).unwrap_or("");
                if want != API_VERSION {
                    return Err(TurboError::new(
                        ErrorCode::ProtocolMismatch,
                        format!("helper speaks API \"{API_VERSION}\", client speaks \"{want}\""),
                    )
                    .into());
                }
                *hello = true;
                let p = self.platform.permissions();
                Ok(json!({"serverApiVersion": API_VERSION, "helperVersion": HELPER_VERSION, "pid": std::process::id(),
                    "permissions": {"accessibility": p.accessibility, "screenRecording": p.screen}}))
            }
            "request" => {
                if !*hello {
                    return Err(TurboError::new(ErrorCode::CallerRejected, "call hello first").into());
                }
                let env = Envelope::parse(params)?;
                if let Some(agent) = env.agent.clone() {
                    self.agents.update(agent);
                }
                self.sessions.lock().unwrap().entry(env.session_id.clone()).or_default().last_touch = Instant::now();
                self.request(&env).map_err(RpcError::from)
            }
            other => Err(RpcError::method_not_found(format!("Unknown method '{other}'"))),
        }
    }

    fn request(&self, env: &Envelope) -> TurboResult<Value> {
        match env.request_type {
            RequestType::AccessStatus => {
                let p = self.platform.permissions();
                Ok(json!({"accessibility": p.accessibility, "screenRecording": p.screen}))
            }
            RequestType::RequestAccess => {
                let p = self.platform.request_permissions();
                Ok(json!({"accessibility": p.accessibility, "screenRecording": p.screen}))
            }
            RequestType::FindApps => Ok(self.find_apps()),
            RequestType::CheckPolicy => {
                let app = self.platform.resolve(&env.app_query()?)?;
                let ev = self.evaluate(&app);
                Ok(json!({"resolved": resolved_json(&app), "decision": if ev.decision == Decision::Allowed {"allowed"} else {"protected"},
                    "risk": if ev.risk == Risk::Sensitive {"sensitive"} else {"normal"}, "reason": ev.reason}))
            }
            RequestType::FinishTurn | RequestType::Reset => Ok(self.end_session(env, env.request_type == RequestType::Reset)),
            RequestType::PreviewPanel => {
                let show = env.payload.get("show").and_then(Value::as_bool).unwrap_or(true);
                *self.preview_forced.lock().unwrap() = Some(show);
                if !show {
                    self.ui.preview(PreviewUpdate::Hide);
                }
                let active = self.last_gated.lock().unwrap().is_some_and(|t| t.elapsed() < PREVIEW_IDLE);
                let has_target = self.preview_target.lock().unwrap().is_some();
                Ok(json!({"visible": show && active && has_target, "enabled": self.settings().preview_enabled, "sessionActive": active}))
            }
            RequestType::ObserveApp | RequestType::Act | RequestType::AppCommands => self.gated(env, None),
            RequestType::WaitFor => self.wait_for(env),
        }
    }

    fn find_apps(&self) -> Value {
        let apps: Vec<Value> = self
            .platform
            .list_apps()
            .into_iter()
            .map(|e| {
                json!({"name": e.app.name, "bundleId": e.app.id, "path": e.app.path, "pid": e.app.pid, "isRunning": e.running,
                    "isActive": e.active, "hasWindow": e.has_window, "lastUsed": e.last_used, "useCount": Value::Null})
            })
            .collect();
        json!({"apps": apps})
    }

    fn end_session(&self, env: &Envelope, keep_approvals: bool) -> Value {
        let mut sessions = self.sessions.lock().unwrap();
        let files = if let Some(s) = sessions.get_mut(&env.session_id) {
            let files = std::mem::take(&mut s.screenshots);
            s.apps.clear();
            if !keep_approvals {
                s.approved.clear();
            }
            s.last_gated = None;
            files
        } else {
            vec![]
        };
        if !keep_approvals {
            sessions.remove(&env.session_id);
        }
        let others_active = sessions.values().any(|s| s.last_gated.is_some_and(|t| t.elapsed() < OVERLAY_IDLE));
        drop(sessions);
        self.stopped.lock().unwrap().remove(&env.session_id);
        for f in &files {
            let _ = std::fs::remove_file(f);
        }
        if !others_active {
            self.overlay_shown.store(false, Ordering::SeqCst);
            self.ui.overlay(OverlayState::Hidden);
            self.ui.preview(PreviewUpdate::Hide);
            self.platform.pointer_hide();
            *self.preview_target.lock().unwrap() = None;
            *self.last_gated.lock().unwrap() = None;
            *self.preview_forced.lock().unwrap() = None;
        }
        log::info(format!("{}: session {} — deleted {} screenshot(s)", env.request_type.name(), protocol::clean(&env.session_id, 8), files.len()));
        json!({"ok": true})
    }

    fn evaluate(&self, app: &AppRef) -> Evaluation {
        let agent = self.agents.current();
        let host_ids = self.platform.host_ids(&agent);
        let policy = SafetyPolicy::new(&self.lists, &host_ids, SafetyPolicy::load_overrides(&self.paths.allow_protected()));
        if let (Some(pid), Some((host, _, _))) = (app.pid, self.platform.host_window(&agent)) {
            if pid == host || pid == std::process::id() {
                return Evaluation {
                    decision: Decision::Protected,
                    risk: Risk::Normal,
                    reason: Some("This is the app the agent itself runs in; an agent may not control its own host.".into()),
                };
            }
        }
        policy.evaluate(&app.id)
    }

    fn check_stop_and_lock(&self, env: &Envelope) -> TurboResult<()> {
        if self.is_stopped(&env.session_id) {
            return Err(TurboError::halted());
        }
        if self.platform.screen_locked() {
            return Err(TurboError::new(ErrorCode::DisplayLocked, "The screen is locked. Wait for the user to unlock it, then try again."));
        }
        Ok(())
    }

    fn gated(&self, env: &Envelope, probe: Option<&mut Probe>) -> TurboResult<Value> {
        let _work = self.work.lock().unwrap_or_else(|e| e.into_inner());
        if env.expired() {
            return Err(TurboError::new(ErrorCode::TimedOut, "The request deadline passed before it could start."));
        }
        self.check_stop_and_lock(env)?;
        if !self.platform.permissions().accessibility {
            return Err(TurboError::new(
                ErrorCode::AccessMissing,
                "Computer Use Turbo does not have the accessibility access it needs; call access_status and ask the user to allow it.",
            ));
        }
        let query = env.app_query()?;
        let step = if env.request_type == RequestType::Act { Some(Step::parse(env.payload.get("step"))?) } else { None };
        if let Some(Step::SendKeys { key }) = &step {
            keys::parse(key)?;
        }
        let app = self.platform.resolve(&query)?;
        let ev = self.evaluate(&app);
        if ev.decision == Decision::Protected {
            return Err(TurboError::new(
                ErrorCode::AppProtected,
                format!("{} ({}) cannot be controlled: {} Do not retry.", app.name, app.id, ev.reason.clone().unwrap_or_default()),
            ));
        }
        let key = app.key();
        if probe.is_some() {
            let sessions = self.sessions.lock().unwrap();
            if !sessions.get(&env.session_id).and_then(|s| s.apps.get(&key)).is_some_and(|a| a.observed) {
                return Err(TurboError::new(ErrorCode::ObserveFirst, format!("No active session for {}: call observe_app first, then wait on what it shows.", app.name)));
            }
            if !app.pid.is_some_and(|p| self.platform.is_running(p)) {
                return Err(TurboError::new(ErrorCode::ObserveFirst, format!("{} is no longer running; call observe_app to relaunch it.", app.name)));
            }
        }
        if step.is_some() {
            let pid = app.pid.filter(|p| self.platform.is_running(*p));
            let sessions = self.sessions.lock().unwrap();
            let observed = sessions.get(&env.session_id).and_then(|s| s.apps.get(&key)).filter(|a| a.observed);
            let Some(state) = observed else {
                return Err(TurboError::new(ErrorCode::ObserveFirst, format!("No active session for {}: call observe_app first, then act on the numbers it returns.", app.name)));
            };
            let Some(pid) = pid else {
                return Err(TurboError::new(ErrorCode::ObserveFirst, format!("{} is no longer running; call observe_app to relaunch it.", app.name)));
            };
            // Take-back.
            if let (Some(input), Some(obs)) = (self.platform.last_input_on(pid), state.last_observed_at) {
                if input > obs {
                    let since = input.elapsed();
                    return Err(if since < TAKE_BACK {
                        let wait = ((TAKE_BACK - since).as_secs_f64().ceil() as u64).max(1);
                        TurboError::new(ErrorCode::UserTookOver, format!("The user is using {} right now, so nothing was sent: wait {wait} s and retry; then call observe_app first, as the app may have changed.", app.name))
                    } else {
                        TurboError::new(ErrorCode::UserTookOver, format!("The user used {} since your last observe_app, so nothing was sent: the app may have changed. Call observe_app for {} again before acting on it.", app.name, app.name))
                    });
                }
            }
        }
        self.approve(env, &app, &ev)?;
        self.check_stop_and_lock(env)?;
        // Overlay + preview.
        *self.last_gated.lock().unwrap() = Some(Instant::now());
        self.sessions.lock().unwrap().entry(env.session_id.clone()).or_default().last_gated = Some(Instant::now());
        self.overlay_shown.store(true, Ordering::SeqCst);
        self.ui.overlay(OverlayState::Active { agent: self.agents.current().name, app: app.name.clone() });

        let mut state = {
            let mut sessions = self.sessions.lock().unwrap();
            let s = sessions.entry(env.session_id.clone()).or_default();
            s.apps.remove(&key).unwrap_or_else(|| AppState::new(app.pid.unwrap_or(0)))
        };
        let result = match (&step, probe) {
            (Some(step), _) => self.act(env, &app, &mut state, step.clone()),
            (None, Some(probe)) => self.check(probe, &app, &mut state),
            (None, None) if env.request_type == RequestType::AppCommands => self.app_commands(env, &app),
            (None, None) => self.observe(env, &app, &mut state),
        };
        if let Some(w) = &state.window {
            *self.preview_target.lock().unwrap() = Some(PreviewTarget { window: w.clone(), app: app.name.clone() });
        }
        let mut sessions = self.sessions.lock().unwrap();
        sessions.entry(env.session_id.clone()).or_default().apps.insert(key, state);
        result
    }

    /// Where the agent pointer goes for a step, and whether the step uses real input there.
    fn pointer_target(&self, pid: u32, step: &PStep<P::Element>) -> Option<(f64, f64, bool)> {
        let el_center = |el: &P::Element| self.platform.element_center(pid, el).map(|(x, y)| (x, y, false));
        match step {
            PStep::Click { target, .. } | PStep::Scroll { target, .. } => match target {
                ActTarget::Point { x, y } => Some((*x, *y, true)),
                ActTarget::Element { el, .. } => el_center(el),
            },
            PStep::Drag { from, .. } => Some((from.0, from.1, true)),
            PStep::WriteText { el: Some(el), .. } | PStep::FillValue { el, .. } | PStep::PickText { el, .. } | PStep::InvokeAction { el, .. } => el_center(el),
            _ => None,
        }
    }

    /// Password managers (sensitive apps) need the user's confirmation in the helper's own
    /// card, once per session; nothing else ever asks.
    fn approve(&self, env: &Envelope, app: &AppRef, ev: &Evaluation) -> TurboResult<()> {
        if ev.risk != Risk::Sensitive {
            return Ok(());
        }
        if self.sessions.lock().unwrap().get(&env.session_id).is_some_and(|s| s.approved.contains(&app.key())) {
            return Ok(());
        }
        let req = ApprovalRequest {
            agent: self.agents.current().name,
            app_name: app.name.clone(),
            app_id: app.id.clone(),
            app_path: app.path.clone(),
            timeout_secs: 120,
        };
        let choice = self.ui.ask(&req);
        log::info(format!("confirmation: {} → {:?}", app.id, choice));
        match choice {
            Choice::Unavailable => Err(TurboError::fault(format!(
                "The confirmation card for {} could not be shown on this computer (its window could not start; see the helper log). Nothing was allowed or declined.",
                app.name
            ))),
            Choice::Deny => Err(TurboError::new(ErrorCode::UserDeclined, format!("The user declined access to {}. Do not retry.", app.name))),
            Choice::Session => {
                self.sessions.lock().unwrap().entry(env.session_id.clone()).or_default().approved.insert(app.key());
                Ok(())
            }
            Choice::Once => Ok(()),
        }
    }

    fn is_self_drawn(&self, app: &AppRef) -> bool {
        self.self_drawn.lock().unwrap().get(&app.key()).copied().unwrap_or(false)
    }

    fn set_self_drawn(&self, app: &AppRef, value: bool) {
        let mut map = self.self_drawn.lock().unwrap();
        if map.get(&app.key()) == Some(&value) {
            return;
        }
        map.insert(app.key(), value);
        let apps: Map<String, Value> = map.iter().map(|(k, v)| (k.clone(), json!({"selfDrawn": v}))).collect();
        let _ = std::fs::write(self.paths.profiles(), serde_json::to_string_pretty(&json!({"version": 1, "apps": apps})).unwrap_or_default());
        log::info(format!("focus: {} {}", app.id, if value { "draws its own UI -> needs the front" } else { "exposes its UI -> background" }));
    }

    /// Wait (≤ 2 s) for a 1 s pause in the user's keyboard / mouse use.
    fn wait_idle(&self, interrupted: &dyn Fn() -> bool) -> bool {
        let until = Instant::now() + MAX_IDLE_WAIT;
        while self.platform.idle_seconds() < QUIET_SECONDS && Instant::now() < until && !interrupted() {
            std::thread::sleep(Duration::from_millis(100));
        }
        self.platform.idle_seconds() >= QUIET_SECONDS
    }

    fn ensure_front_for_self_drawn(&self, app: &AppRef, pid: u32, window: Option<&WindowInfo>) {
        if self.is_self_drawn(app) && self.platform.frontmost_pid() != Some(pid) && self.wait_idle(&|| false) {
            let ok = self.platform.activate(pid, window);
            log::info(format!("focus: brought {} to the front (draws its own UI) → {}", app.id, if ok { "in front" } else { "failed" }));
        }
    }

    // ---------------------------------------------------------------- observe

    fn observe(&self, env: &Envelope, app_in: &AppRef, state: &mut AppState<P::Element>) -> TurboResult<Value> {
        let mut app = app_in.clone();
        if app.pid.map_or(true, |p| !self.platform.is_running(p)) {
            app = self.platform.launch(&app)?;
        }
        let pid = app.pid.ok_or_else(|| TurboError::fault("The launched app has no process id."))?;
        if state.pid != pid {
            state.relaunched(pid);
        }
        self.ensure_front_for_self_drawn(&app, pid, state.window.as_ref());
        self.platform.watch(pid);
        // Settle after the previous action.
        if let Some(end) = state.last_action_end {
            let left = SETTLE.saturating_sub(end.elapsed());
            let budget = Duration::from_secs_f64((env.seconds_left() - 3.0).max(0.0));
            std::thread::sleep(left.min(budget));
        }
        let read_started = Instant::now();
        let deadline = Instant::now() + Duration::from_secs_f64((env.seconds_left() - 3.0).clamp(0.5, 8.0));
        let snap = self.platform.snapshot(&app, deadline)?;
        let tree = self.number(state, &snap);
        // Only what this observation shows stays addressable.
        let shown: HashSet<usize> = tree.elems.iter().map(|e| e.index).collect();
        state.elements.retain(|i, _| shown.contains(i));
        state.secure.extend(tree.elems.iter().filter(|e| e.secure).map(|e| e.index));
        // Menu bar leaving the scope is not "removed".
        let menu: HashSet<usize> = tree.elems.iter().filter(|e| e.in_menu_bar).map(|e| e.index).collect();
        let ignore = if menu.is_empty() { state.menu_bar.clone() } else { HashSet::new() };
        if !menu.is_empty() {
            state.menu_bar = menu;
        }

        let mut header = vec![format!("App: {} ({}) pid {pid}", app.name, app.id)];
        let mut notes = vec![];
        let mut shot_json = Value::Null;
        let mut window_json = Value::Null;
        let mut change = None;
        state.window = snap.window.clone();
        state.geometry = None;
        if let Some(w) = &snap.window {
            let f = w.frame;
            header.push(format!("Window: \"{}\" {}x{} at ({},{})", tree::escape(&w.title, 120), f.w as i64, f.h as i64, f.x as i64, f.y as i64));
            window_json = json!({"x": f.x as i64, "y": f.y as i64, "width": f.w as i64, "height": f.h as i64});
            let g = image_util::fit(f.w, f.h);
            state.geometry = Some(g);
            let mut captured = false;
            if self.platform.permissions().screen {
                if let Some(img) = self.platform.capture(w) {
                    let name = format!("{:x}{:x}", protocol::now_ms(), std::process::id());
                    match image_util::save(&img, &g, &self.paths.shots, &name) {
                        Ok(shot) => {
                            captured = true;
                            if shot.possibly_blank {
                                notes.push("Note: the screenshot may be blank (app still rendering?); observe again, or rely on the accessibility tree.".into());
                            }
                            if state.observed {
                                if let Some(prev) = &state.last_thumb {
                                    change = image_util::change_fraction(prev, &shot.thumbnail);
                                }
                            }
                            state.last_thumb = Some(shot.thumbnail.clone());
                            self.sessions.lock().unwrap().entry(env.session_id.clone()).or_default().screenshots.push(shot.path.clone());
                            shot_json = json!({"path": shot.path.to_string_lossy(), "mimeType": "image/jpeg", "width": shot.width, "height": shot.height, "scale": shot.scale});
                        }
                        Err(e) => log::error(format!("screenshot write failed: {e}")),
                    }
                } else {
                    notes.push(self.platform.capture_note(w).unwrap_or_else(|| "Note: the window could not be captured (it may be minimized or on another desktop).".into()));
                }
            } else {
                notes.push("Note: screen capture is not allowed, so no screenshot was captured; element and coordinate actions still work.".into());
            }
            header.push(if g.scale < 1.0 {
                format!("Screenshot: {}x{} px, scale {} (downscaled; x/y arguments are pixels in this screenshot, screen point = window origin + pixel / scale)", g.width, g.height, fmt_scale(g.scale))
            } else if captured {
                format!("Screenshot: {}x{} px, scale 1 (x/y arguments are pixels in this screenshot = window pixels)", g.width, g.height)
            } else {
                format!("Screenshot: none; x/y arguments are pixels of a {}x{} screenshot of the window", g.width, g.height)
            });
        } else {
            header.push("Window: none".into());
            notes.push(format!("Note: {} has no on-screen window, so there is no screenshot.", app.name));
        }
        if let Some(pl) = &snap.page_loading {
            header.push(format!("Page loading: {pl}"));
        }
        notes.extend(snap.notes.iter().cloned());
        if snap.cut_short {
            notes.push("… accessibility read stopped early (very large or unresponsive app); act on visible elements or scroll".into());
        }
        // What happened in the app since the previous observation.
        if let (true, Some(since), Some(log)) = (state.observed, state.last_observed_at, self.platform.events()) {
            notes.extend(events::since_last_look(&log.since(pid, since)));
        }
        let area = snap.window.as_ref().map_or(0.0, |w| w.frame.w * w.frame.h);
        let sparse = tree::is_sparse(&tree, area, snap.has_web);
        if snap.window.is_some() {
            self.set_self_drawn(&app, sparse);
        }
        let focused_index = snap.focused.and_then(|fi| tree.elems.iter().find(|e| e.element == Some(fi)).map(|e| e.index));
        let full = env.payload.get("fullTree").and_then(Value::as_bool).unwrap_or(false);
        let prev = state.baseline.clone();
        let rendered = tree::render(&Observation {
            header,
            notes,
            tree: &tree,
            previous: if state.observed { prev.as_ref() } else { None },
            ignore_removed: ignore,
            full_tree: full,
            focused_index,
            selected_text: snap.selected_text.clone(),
            sparse,
            screenshot_change: change,
        });
        state.baseline = Some(tree.baseline());
        state.windows_at_observation = Some(self.platform.window_handles(pid));
        state.observed = true;
        state.last_observed_at = Some(read_started);
        state.last_action_end = None;
        log::info(format!("observeApp {} pid {pid}: {} elements, diff={}", app.id, tree.elems.len(), rendered.is_diff));
        let mut resolved = app.clone();
        resolved.pid = Some(pid);
        Ok(json!({"resolved": resolved_json(&resolved), "text": rendered.text, "screenshot": shot_json, "window": window_json, "isDiff": rendered.is_diff}))
    }

    // ---------------------------------------------------------------- act

    /// Number a fresh read's elements (an element keeps its number while it lives) and
    /// remember the live element behind each number.
    fn number(&self, state: &mut AppState<P::Element>, snap: &Snapshot<P::Element>) -> tree::SerializedTree {
        let mut indexer = std::mem::take(&mut state.indexer);
        let (elements, platform) = (&state.elements, &self.platform);
        let tree = tree::serialize(&snap.roots, &mut indexer, &mut |i| elements.get(&i).is_some_and(|e| platform.is_alive(e)));
        state.indexer = indexer;
        for e in &tree.elems {
            if let Some(el) = e.element.and_then(|ei| snap.elements.get(ei)) {
                state.elements.insert(e.index, el.clone());
            }
        }
        tree
    }

    /// Live element for a number: the retained one, else a fresh read matched by path key.
    fn element(&self, app: &AppRef, state: &mut AppState<P::Element>, index: usize) -> TurboResult<P::Element> {
        if let Some(el) = state.elements.get(&index) {
            if self.platform.is_alive(el) {
                return Ok(el.clone());
            }
        }
        if !state.indexer.knows(index) {
            return Err(TurboError::stale(index));
        }
        let snap = self.platform.snapshot(app, Instant::now() + Duration::from_secs(3))?;
        self.number(state, &snap);
        state.elements.get(&index).filter(|e| self.platform.is_alive(e)).cloned().ok_or_else(|| TurboError::stale(index))
    }

    fn refuse_secure(&self, state: &AppState<P::Element>, index: usize, el: &P::Element) -> TurboResult<()> {
        if state.secure.contains(&index) || self.platform.is_secure(el) {
            return Err(password_error());
        }
        Ok(())
    }

    fn refuse_secure_focus(&self, pid: u32, app: &str) -> TurboResult<()> {
        match self.platform.focused_secure(pid) {
            Some(false) => Ok(()),
            Some(true) => Err(password_error()),
            None => Err(TurboError::action(format!("{app} did not say what is focused, so the input was refused to avoid a possible password field; retry."))),
        }
    }

    fn to_screen(&self, state: &AppState<P::Element>, app: &AppRef, x: f64, y: f64) -> TurboResult<(f64, f64)> {
        let window = state.window.as_ref().ok_or_else(|| TurboError::new(ErrorCode::NoWindow, format!("{} has no window to target; call observe_app again.", app.name)))?;
        let frame = self.platform.live_frame(window).unwrap_or(window.frame);
        let g: Geometry = state.geometry.unwrap_or_else(|| image_util::fit(frame.w, frame.h));
        if !image_util::contains(x, y, &g) {
            return Err(TurboError::bad(format!("({x}, {y}) is outside the window screenshot ({}x{} px); x/y are pixels of the latest observe_app screenshot.", g.width, g.height)));
        }
        Ok(image_util::to_screen(x, y, (frame.x, frame.y), &g))
    }

    fn act(&self, env: &Envelope, app: &AppRef, state: &mut AppState<P::Element>, step: Step) -> TurboResult<Value> {
        let pid = app.pid.ok_or_else(|| TurboError::new(ErrorCode::ObserveFirst, format!("{} is not running; call observe_app.", app.name)))?;
        let interrupted = || self.is_stopped(&env.session_id) || self.platform.screen_locked() || env.expired();
        let pstep = match step.clone() {
            Step::Click { target, button, times } => PStep::Click { target: self.act_target(app, state, target)?, button, times },
            Step::Scroll { target, direction, pages } => PStep::Scroll { target: self.act_target(app, state, target)?, direction, pages },
            Step::Drag { from, to } => PStep::Drag { from: self.to_screen(state, app, from.0, from.1)?, to: self.to_screen(state, app, to.0, to.1)? },
            Step::WriteText { text, element } => {
                let el = match element {
                    Some(i) => {
                        let el = self.element(app, state, i)?;
                        self.refuse_secure(state, i, &el)?;
                        Some(el)
                    }
                    None => {
                        self.refuse_secure_focus(pid, &app.name)?;
                        None
                    }
                };
                PStep::WriteText { text, el }
            }
            Step::SendKeys { key } => {
                self.refuse_secure_focus(pid, &app.name)?;
                PStep::SendKeys { chord: keys::parse(&key)?, shown: protocol::clean(&key, 40) }
            }
            Step::FillValue { element, value } => {
                let el = self.element(app, state, element)?;
                self.refuse_secure(state, element, &el)?;
                PStep::FillValue { el, value }
            }
            Step::PickText { element, text, prefix, suffix, mode } => {
                let el = self.element(app, state, element)?;
                self.refuse_secure(state, element, &el)?;
                let hay = self.platform.element_text(&el).ok_or_else(|| TurboError::new(ErrorCode::NotSupported, format!("#{element} has no text value to select in.")))?;
                let (start, len) = find_text(&hay, &text, prefix.as_deref(), suffix.as_deref())
                    .ok_or_else(|| TurboError::bad(format!("Text \"{}\" was not found in #{element} (with the given prefix/suffix).", protocol::clean(&text, 60))))?;
                PStep::PickText { el, start, len, mode }
            }
            Step::InvokeAction { element, name } => PStep::InvokeAction { el: self.element(app, state, element)?, name },
            Step::PasteText { text, format } => {
                self.refuse_secure_focus(pid, &app.name)?;
                PStep::PasteText { text, format }
            }
            Step::RunCommand { path } => {
                let shown = events::display_path(&path);
                if path.len() < 2 {
                    return Err(TurboError::bad(format!("\"{shown}\" is a whole menu; name a command inside it (use find_command).")));
                }
                match self.platform.locate_command(app, &path) {
                    None => {
                        return Err(TurboError::bad(format!(
                            "{} has no menu command {shown} right now (menus can change with the window or document in front). Call find_command to see the current commands.",
                            app.name
                        )))
                    }
                    Some(l) if l.has_submenu => {
                        return Err(TurboError::bad(format!("{} opens a submenu; name one of its commands (use find_command).", events::display_path(&l.path))))
                    }
                    Some(_) => PStep::RunCommand { path },
                }
            }
        };
        self.ensure_front_for_self_drawn(app, pid, state.window.as_ref());
        let front = self.platform.frontmost_pid() == Some(pid);
        let borrowed: RefCell<Option<(Option<u32>, Instant)>> = RefCell::new(None);
        let settings = self.settings();
        let borrow = |what: &str| -> TurboResult<()> {
            if self.platform.frontmost_pid() == Some(pid) {
                return Ok(());
            }
            if !settings.borrow_front {
                return Err(TurboError::new(ErrorCode::UserActive, texts::borrow_off(&app.name, what)));
            }
            if !self.wait_idle(&interrupted) {
                return Err(TurboError::new(ErrorCode::UserActive, texts::borrow_busy(&app.name, what)));
            }
            let previous = self.platform.frontmost_pid();
            if !self.platform.activate(pid, state.window.as_ref()) {
                let msg = self
                    .platform
                    .activate_hint(pid, what)
                    .unwrap_or_else(|| format!("{} could not be brought to the front for {what}. Nothing was sent; retry, or ask the user to bring it forward.", app.name));
                return Err(TurboError::new(ErrorCode::UserActive, msg));
            }
            if borrowed.borrow().is_none() {
                *borrowed.borrow_mut() = Some((previous.filter(|p| *p != pid), Instant::now()));
            }
            log::info(format!("borrow front: {} for {what}", app.id));
            Ok(())
        };
        let need_idle = |what: &str| -> TurboResult<()> {
            if self.wait_idle(&interrupted) {
                Ok(())
            } else {
                Err(TurboError::new(ErrorCode::UserActive, format!("{} needs the real mouse pointer for a moment, but the user is using the mouse or keyboard right now. Nothing was sent. Retry in a few seconds.", texts::capitalize(what))))
            }
        };
        let still_front = || self.platform.frontmost_pid() == Some(pid);
        let ctx = ActCtx {
            app,
            pid,
            window: state.window.as_ref(),
            front,
            self_drawn: self.is_self_drawn(app),
            borrow_front: &borrow,
            need_idle: &need_idle,
            interrupted: &interrupted,
            still_front: &still_front,
            notes: RefCell::new(vec![]),
        };
        if !front && !ctx.self_drawn && !state.background_noted {
            ctx.note(texts::background_note(&app.name));
            state.background_noted = true;
        }
        let started = Instant::now();
        let windows_before = matches!(step, Step::RunCommand { .. }).then(|| self.platform.window_handles(pid));
        // The agent pointer glides to the target first; input waits until it arrives.
        let clicked = matches!(pstep, PStep::Click { .. });
        if settings.pointer_enabled {
            if let Some((x, y, real_input)) = self.pointer_target(pid, &pstep) {
                let show = real_input || self.platform.frontmost_pid() == Some(pid);
                if let Some(travel) = self.platform.pointer_glide(pid, x, y, show, settings.pointer_speed) {
                    let arrive = Instant::now() + travel.min(Duration::from_millis(2500));
                    while Instant::now() < arrive {
                        if interrupted() {
                            return Err(TurboError::new(ErrorCode::HaltedByUser, "The user stopped Computer Use. Nothing was sent."));
                        }
                        std::thread::sleep(Duration::from_millis(20));
                    }
                }
            }
        }
        let result = self.platform.act(&ctx, pstep);
        if clicked && result.is_ok() && settings.pointer_enabled {
            self.platform.pointer_click();
        }
        if let (Some(before), Ok(_)) = (&windows_before, &result) {
            // A command meant for a window may have opened a new one instead: say so.
            std::thread::sleep(Duration::from_millis(300));
            if self.platform.window_handles(pid).iter().any(|h| !before.contains(h)) {
                ctx.note("A new window or dialog opened. If the command was meant for a window that was already open, observe_app and check where it acted.");
            }
        }
        // Hand a borrowed front back.
        if let Some((previous, at)) = borrowed.borrow().filter(|_| !self.platform.keeps_front(pid)) {
            let held = at.elapsed();
            if held < BORROW_HOLD {
                std::thread::sleep(BORROW_HOLD - held);
            }
            let user_since = self.platform.idle_seconds() < at.elapsed().as_secs_f64();
            if let Some(prev) = previous {
                if self.platform.frontmost_pid() == Some(pid) && !user_since {
                    self.platform.activate(prev, None);
                    ctx.note(texts::borrowed_note(&app.name, self.platform.app_name_of_pid(prev).as_deref()));
                }
            }
        }
        state.last_action_end = Some(Instant::now());
        let note = result?;
        let mut notes: Vec<String> = note.into_iter().collect();
        notes.extend(ctx.notes.into_inner());
        log::info(format!("act {} on {} done in {} ms", step.type_name(), app.id, started.elapsed().as_millis()));
        Ok(json!({"ok": true, "note": if notes.is_empty() { Value::Null } else { Value::String(notes.join(" ")) }}))
    }

    // ---------------------------------------------------------------- app commands

    /// `appCommands {app, knownSignature?, checkPaths?, launch?}`.
    fn app_commands(&self, env: &Envelope, app_in: &AppRef) -> TurboResult<Value> {
        let mut app = app_in.clone();
        if app.pid.map_or(true, |p| !self.platform.is_running(p)) {
            if !env.payload.get("launch").and_then(Value::as_bool).unwrap_or(true) {
                return Ok(json!({"resolved": resolved_json(&app), "running": false}));
            }
            app = self.platform.launch(&app)?;
        }
        let started = Instant::now();
        let signature = self.platform.menu_signature(&app);
        let mut out = json!({"resolved": resolved_json(&app), "running": true, "signature": signature});
        if !signature.is_empty() && env.payload.get("knownSignature").and_then(Value::as_str) == Some(signature.as_str()) {
            out["unchanged"] = json!(true);
        } else {
            let read = self.platform.menu_commands(&app, Instant::now() + Duration::from_secs(6));
            log::info(format!("appCommands {}: read {} command(s) in {} ms{}", app.id, read.commands.len(), started.elapsed().as_millis(), if read.truncated { " (cut short)" } else { "" }));
            out["commands"] = Value::Array(read.commands.iter().map(events::Command::json).collect());
            out["truncated"] = json!(read.truncated);
        }
        if let Some(paths) = env.payload.get("checkPaths").and_then(Value::as_array) {
            let states: Vec<Value> = paths
                .iter()
                .take(50)
                .map(|p| {
                    let titles: Vec<String> = p.as_array().map(|a| a.iter().filter_map(Value::as_str).map(str::to_string).collect()).unwrap_or_default();
                    match self.platform.locate_command(&app, &titles) {
                        Some(l) => json!({"enabled": l.enabled && !l.has_submenu}),
                        None => Value::Null,
                    }
                })
                .collect();
            out["states"] = Value::Array(states);
        }
        Ok(out)
    }

    // ---------------------------------------------------------------- waiting

    /// `waitFor {app, until, text?, elementNumber?, timeoutMs?}`: check, then again
    /// after each burst of the app's events (at least every 0.5 s), until the condition holds
    /// or the time is up. Each check runs the whole safety pipeline (Stop ends the wait); the
    /// work lock is not held in between.
    fn wait_for(&self, env: &Envelope) -> TurboResult<Value> {
        let payload = Value::Object(env.payload.clone());
        let mut probe = Probe::new(WaitCondition::parse(&payload)?);
        let timeout = WaitCondition::timeout(&payload)?;
        let begin = Instant::now();
        let until = begin + timeout.min(Duration::from_secs_f64((env.seconds_left() - 2.0).max(0.2)));
        loop {
            self.gated(env, Some(&mut probe))?;
            let now = Instant::now();
            if probe.matched || now >= until {
                break;
            }
            let pause = Duration::from_millis(if probe.condition == WaitCondition::Settled { 200 } else { 500 }).min(until - now);
            match self.platform.events() {
                Some(log) => {
                    log.wait(probe.pid, probe.last_check, pause);
                    if probe.condition != WaitCondition::Settled {
                        std::thread::sleep(Duration::from_millis(120));
                    }
                }
                None => std::thread::sleep(pause),
            }
        }
        let waited = begin.elapsed();
        let lines = match (self.platform.events(), probe.started) {
            (Some(log), Some(start)) => events::summary(&log.since(probe.pid, start), 15),
            _ => vec![],
        };
        log::info(format!("waitFor {:?}: {} after {} ms", probe.condition, if probe.matched { "matched" } else { "timed out" }, waited.as_millis()));
        Ok(json!({"matched": probe.matched, "waitedMs": waited.as_millis() as u64, "detail": probe.detail, "events": lines}))
    }

    /// One check of a `waitFor`, under the work lock after the safety pipeline.
    fn check(&self, probe: &mut Probe, app: &AppRef, state: &mut AppState<P::Element>) -> TurboResult<Value> {
        let pid = app.pid.ok_or_else(|| TurboError::new(ErrorCode::ObserveFirst, format!("{} is not running; call observe_app.", app.name)))?;
        let now = Instant::now();
        let first = probe.started.is_none();
        if first {
            probe.pid = pid;
            probe.started = Some(now);
            self.platform.watch(pid);
        }
        let started = probe.started.unwrap_or(now);
        let snapshot_texts = |me: &Self| -> TurboResult<Vec<String>> {
            Ok(events::texts(&me.platform.snapshot(app, Instant::now() + Duration::from_secs(3))?.roots))
        };
        match probe.condition.clone() {
            WaitCondition::TextAppears(t) => {
                if snapshot_texts(self)?.iter().any(|s| events::contains_text(s, &t)) {
                    probe.hit(format!("\"{}\" is shown in {}.", protocol::clean(&t, 80), app.name));
                }
            }
            WaitCondition::TextGone(t) => {
                if !snapshot_texts(self)?.iter().any(|s| events::contains_text(s, &t)) {
                    probe.hit(format!("\"{}\" is no longer shown in {}.", protocol::clean(&t, 80), app.name));
                }
            }
            WaitCondition::ElementChanges(index) => {
                let line = self.element_line(app, state, index);
                if first {
                    if line.is_none() {
                        return Err(TurboError::stale(index));
                    }
                    probe.base_element = line;
                } else if line != probe.base_element {
                    probe.hit(if line.is_none() { format!("#{index} is gone.") } else { format!("#{index} changed.") });
                }
            }
            WaitCondition::NewWindow => {
                let handles = self.platform.window_handles(pid);
                // Since the latest observation: a window the previous action opened counts.
                if first {
                    probe.base_windows = state.windows_at_observation.clone().unwrap_or_else(|| handles.clone());
                }
                let since = state.last_observed_at.unwrap_or(started).min(started);
                let opened = self.platform.events().is_some_and(|l| {
                    l.since(pid, since).iter().any(|e| matches!(e.kind, events::EventKind::WindowOpened | events::EventKind::DialogOpened))
                });
                if handles.iter().any(|h| !probe.base_windows.contains(h)) {
                    probe.hit(format!("A new window opened in {}.", app.name));
                } else if opened {
                    probe.hit(format!("A window or dialog opened in {}.", app.name));
                }
            }
            WaitCondition::Settled => {
                let last = [self.platform.events().and_then(|l| l.last(pid)), state.last_action_end, Some(started)].into_iter().flatten().max().unwrap_or(started);
                let snap = self.platform.snapshot(app, Instant::now() + Duration::from_secs(3))?;
                let loading = snap.page_loading.as_deref().is_some_and(|p| p.starts_with("yes"));
                let fingerprint = events::texts(&snap.roots).join("\u{1f}");
                // Without events, "quiet" means the content did not change between two checks.
                let quiet = if self.platform.events().is_some() {
                    last.elapsed() >= Duration::from_secs(1)
                } else {
                    let same = probe.base_texts.as_deref() == Some(fingerprint.as_str());
                    probe.base_texts = Some(fingerprint);
                    same && started.elapsed() >= Duration::from_secs(1)
                };
                if !first && quiet && !loading {
                    probe.hit(format!("{} has been quiet for at least 1 s.", app.name));
                }
            }
            WaitCondition::AnyChange => {
                let fingerprint = snapshot_texts(self)?.join("\u{1f}");
                if first {
                    probe.base_texts = Some(fingerprint);
                } else if probe.base_texts.as_deref() != Some(fingerprint.as_str()) {
                    probe.hit(format!("The content of {} changed.", app.name));
                } else if let Some(e) = self.platform.events().and_then(|l| l.since(pid, started).into_iter().find(|e| e.kind != events::EventKind::FocusMoved)) {
                    probe.hit(format!("Something changed in {}: {}.", app.name, e.line()));
                }
            }
        }
        probe.last_check = now;
        Ok(json!({"matched": probe.matched}))
    }

    /// The current line of element `index` (label, value, state), None when it is gone.
    fn element_line(&self, app: &AppRef, state: &mut AppState<P::Element>, index: usize) -> Option<String> {
        let snap = self.platform.snapshot(app, Instant::now() + Duration::from_secs(3)).ok()?;
        let tree = self.number(state, &snap);
        tree.elems.iter().find(|e| e.index == index).map(|e| e.line.clone())
    }

    fn act_target(&self, app: &AppRef, state: &mut AppState<P::Element>, target: Target) -> TurboResult<ActTarget<P::Element>> {
        Ok(match target {
            Target::Element(index) => ActTarget::Element { index, el: self.element(app, state, index)? },
            Target::Point(x, y) => {
                let (sx, sy) = self.to_screen(state, app, x, y)?;
                ActTarget::Point { x: sx, y: sy }
            }
        })
    }
}

/// State of one `waitFor` across its checks.
struct Probe {
    condition: WaitCondition,
    pid: u32,
    started: Option<Instant>,
    last_check: Instant,
    base_windows: Vec<u64>,
    base_element: Option<String>,
    base_texts: Option<String>,
    matched: bool,
    detail: String,
}

impl Probe {
    fn new(condition: WaitCondition) -> Self {
        Self {
            condition,
            pid: 0,
            started: None,
            last_check: Instant::now(),
            base_windows: vec![],
            base_element: None,
            base_texts: None,
            matched: false,
            detail: String::new(),
        }
    }
    fn hit(&mut self, detail: String) {
        self.matched = true;
        self.detail = detail;
    }
}

fn password_error() -> TurboError {
    TurboError::new(ErrorCode::PasswordGuard, "The target is a password field. Computer Use never types into or reads password fields; ask the user to enter it.")
}

fn fmt_scale(s: f64) -> String {
    let t = format!("{s:.4}");
    t.trim_end_matches('0').trim_end_matches('.').to_string()
}

pub fn resolved_json(app: &AppRef) -> Value {
    json!({"name": app.name, "bundleId": app.id, "path": app.path, "pid": app.pid})
}
