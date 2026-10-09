//! Wayland: screenshots and real input go through one "link" for the whole session: a portal
//! session sharing the screen — every monitor, as PipeWire streams — with remote input (EIS).
//! The user approves it once (choose the screen, allow remote interaction, remember); the
//! approval is saved as a restore token, so later links start silently, for every app.
//! Reading the UI and accessibility actions need no link.
//!
//! Wayland does not tell other clients where windows are, so a screenshot is the whole
//! desktop and x/y are desktop pixels (logical); the input devices' regions use the same
//! coordinates, so a screenshot pixel is exactly where a click lands.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use image::RgbaImage;
use turbo_core::platform::Rect;

use super::eis::Eis;
use super::portal::{Portal, StartError};
use super::screencast::Frames;

/// Whether this is a Wayland session (X11 may still be there for XWayland apps).
pub fn session_is_wayland() -> bool {
    std::env::var("WAYLAND_DISPLAY").is_ok_and(|v| !v.is_empty()) || std::env::var("XDG_SESSION_TYPE").is_ok_and(|v| v == "wayland")
}

struct Monitor {
    frames: Arc<Frames>,
    position: (i32, i32),
    size: (i32, i32),
}

pub struct Link {
    monitors: Vec<Monitor>,
    pub eis: Option<Arc<Eis>>,
    closed: Arc<AtomicBool>,
}

impl Link {
    pub fn alive(&self) -> bool {
        !self.closed.load(Ordering::SeqCst) && self.monitors.iter().any(|m| m.frames.alive.load(Ordering::SeqCst))
    }

    /// The desktop: the bounding box of the shared monitors (logical pixels).
    pub fn desktop(&self) -> Rect {
        let (mut x0, mut y0, mut x1, mut y1) = (i32::MAX, i32::MAX, i32::MIN, i32::MIN);
        for m in &self.monitors {
            x0 = x0.min(m.position.0);
            y0 = y0.min(m.position.1);
            x1 = x1.max(m.position.0 + m.size.0);
            y1 = y1.max(m.position.1 + m.size.1);
        }
        if x1 <= x0 || y1 <= y0 {
            return Rect { x: 0.0, y: 0.0, w: 0.0, h: 0.0 };
        }
        Rect { x: x0 as f64, y: y0 as f64, w: (x1 - x0) as f64, h: (y1 - y0) as f64 }
    }

    /// The desktop as one image: each monitor's latest frame at its place (frames of scaled
    /// monitors are brought to logical size).
    pub fn image(&self, wait: Duration) -> Option<RgbaImage> {
        let d = self.desktop();
        if d.w < 1.0 || d.h < 1.0 {
            return None;
        }
        let mut out = RgbaImage::new(d.w as u32, d.h as u32);
        let mut any = false;
        for m in &self.monitors {
            let Some(f) = m.frames.latest(wait) else { continue };
            let (w, h) = (m.size.0.max(1) as u32, m.size.1.max(1) as u32);
            let img = if f.image.dimensions() == (w, h) { f.image } else { image::imageops::resize(&f.image, w, h, image::imageops::FilterType::Triangle) };
            image::imageops::replace(&mut out, &img, (m.position.0 as f64 - d.x) as i64, (m.position.1 as f64 - d.y) as i64);
            any = true;
        }
        any.then_some(out)
    }

    pub fn input(&self) -> Option<&Arc<Eis>> {
        self.eis.as_ref().filter(|e| e.alive.load(Ordering::SeqCst))
    }
}

#[derive(Clone)]
enum Status {
    Asking,
    Declined(Instant),
    /// The user ended sharing (the desktop's "stop sharing" control).
    Stopped(Instant),
    Failed(String),
}

pub struct Links {
    portal: Arc<Portal>,
    link: Arc<Mutex<Option<Arc<Link>>>>,
    status: Arc<Mutex<Option<Status>>>,
    tokens: Tokens,
}

/// The saved approval (portal restore token).
#[derive(Clone)]
struct Tokens(PathBuf);

const TOKEN_KEY: &str = "screen";

impl Tokens {
    fn load(&self) -> Option<String> {
        let all: serde_json::Value = std::fs::read_to_string(&self.0).ok().and_then(|t| serde_json::from_str(&t).ok())?;
        all.get(TOKEN_KEY)?.as_str().map(str::to_string)
    }

    fn save(&self, token: Option<&str>) {
        let all = match token {
            Some(t) => serde_json::json!({ TOKEN_KEY: t }),
            None => serde_json::json!({}),
        };
        if let Ok(text) = serde_json::to_string_pretty(&all) {
            let tmp = self.0.with_extension("tmp");
            if std::fs::write(&tmp, text).is_ok() {
                let _ = std::fs::rename(&tmp, &self.0);
            }
        }
    }
}

/// How long the sharing prompt stays up waiting for the user (it is closed after that; the
/// next look asks again).
const ASK_FOR: Duration = Duration::from_secs(600);
/// After "Cancel" or "Stop sharing", the user is not asked again this soon.
const QUIET: Duration = Duration::from_secs(600);

impl Links {
    pub fn new(tokens: PathBuf) -> Option<Self> {
        let portal = Portal::connect()?;
        if !portal.supported() {
            turbo_core::log::error("Wayland: the desktop portal has no screen sharing with remote input (RemoteDesktop 2 / ScreenCast 4); no screenshots or real input for Wayland windows");
            return None;
        }
        Some(Self { portal: Arc::new(portal), link: Default::default(), status: Default::default(), tokens: Tokens(tokens) })
    }

    /// The live link, if any.
    pub fn get(&self) -> Option<Arc<Link>> {
        let mut link = self.link.lock().unwrap();
        match link.as_ref() {
            Some(l) if l.alive() => Some(l.clone()),
            Some(l) => {
                if l.closed.load(Ordering::SeqCst) {
                    *self.status.lock().unwrap() = Some(Status::Stopped(Instant::now()));
                }
                *link = None;
                None
            }
            None => None,
        }
    }

    /// The link, opening it if needed (the first time the user is asked; then this returns
    /// None and the link appears once they answer).
    pub fn ensure(&self, wait: Duration) -> Option<Arc<Link>> {
        if let Some(l) = self.get() {
            return Some(l);
        }
        {
            let mut status = self.status.lock().unwrap();
            match status.as_ref() {
                Some(Status::Asking) => {}
                Some(Status::Declined(at) | Status::Stopped(at)) if at.elapsed() < QUIET => return None,
                _ => {
                    *status = Some(Status::Asking);
                    self.open();
                }
            }
        }
        let until = Instant::now() + wait;
        while Instant::now() < until {
            if let Some(l) = self.get() {
                return Some(l);
            }
            if !matches!(self.status.lock().unwrap().as_ref(), Some(Status::Asking)) {
                return None;
            }
            std::thread::sleep(Duration::from_millis(40));
        }
        None
    }

    fn open(&self) {
        let portal = self.portal.clone();
        let (slot, status, tokens) = (self.link.clone(), self.status.clone(), self.tokens.clone());
        let token = tokens.load();
        std::thread::Builder::new()
            .name("portal".into())
            .spawn(move || {
                let started = Instant::now();
                let result = match portal.start(token.as_deref(), ASK_FOR) {
                    Ok(s) => {
                        tokens.save(s.restore_token.as_deref());
                        let mut monitors = vec![];
                        for st in &s.streams {
                            if let Some(fd) = portal.pipewire(&s.session) {
                                monitors.push(Monitor { frames: Frames::start(fd, st.node), position: st.position, size: st.size });
                            }
                        }
                        if monitors.is_empty() {
                            portal.close(&s.session);
                            Err(Status::Failed("the screen stream could not be opened".into()))
                        } else {
                            let eis = if s.keyboard_and_pointer { portal.eis(&s.session).and_then(Eis::connect) } else { None };
                            let closed = Arc::new(AtomicBool::new(false));
                            portal.watch_closed(&s.session, closed.clone());
                            turbo_core::log::info(format!("wayland: screen shared ({} monitor(s)) after {} ms, input: {}", monitors.len(), started.elapsed().as_millis(), eis.is_some()));
                            Ok(Arc::new(Link { monitors, eis, closed }))
                        }
                    }
                    Err(StartError::Declined) => {
                        tokens.save(None);
                        Err(Status::Declined(Instant::now()))
                    }
                    Err(StartError::NoAnswer) => Err(Status::Failed("the user did not answer the sharing prompt".into())),
                    Err(StartError::Failed(m)) => {
                        turbo_core::log::error(format!("wayland: sharing the screen failed: {m}"));
                        Err(Status::Failed(m))
                    }
                };
                match result {
                    Ok(link) => {
                        *slot.lock().unwrap() = Some(link);
                        *status.lock().unwrap() = None;
                    }
                    Err(st) => *status.lock().unwrap() = Some(st),
                }
            })
            .ok();
    }

    /// Why there is no screenshot, in words for the agent.
    pub fn note(&self) -> Option<String> {
        if self.get().is_some() {
            return None;
        }
        Some(match self.status.lock().unwrap().as_ref() {
            Some(Status::Asking) | None => "Note: no screenshot yet: the desktop is asking the user, once, to share the screen. Tell the user: in the \"Remote Desktop\" window, turn on \"Allow Remote Interaction\", keep \"Remember This Selection\" ticked and click Share (if they cannot see that window, it is behind others: Alt+Tab or the desktop's notification brings it up). Meanwhile keep working with element numbers (clicks, typing into fields, menu commands work without sharing); observe again after the user answers.".into(),
            Some(Status::Declined(_)) => "Note: no screenshot: the user did not share the screen. Element numbers and accessibility actions still work; clicks at x/y and key presses do not.".into(),
            Some(Status::Stopped(_)) => "Note: no screenshot: the user stopped sharing the screen. Element numbers and accessibility actions still work; clicks at x/y and key presses do not.".into(),
            Some(Status::Failed(m)) => format!("Note: no screenshot: sharing the screen failed ({m}). Element numbers and accessibility actions still work."),
        })
    }

    /// When we last sent real input.
    pub fn last_input(&self) -> Option<Instant> {
        self.link.lock().unwrap().as_ref().and_then(|l| l.eis.as_ref().and_then(|e| *e.last_sent.lock().unwrap()))
    }
}

/// `--share-screen` (run by the installer): ask the user now, while they set things up, so
/// no task is ever interrupted by the prompt. The approval is saved; later shares start
/// silently. Exit code 0 = shared with remote interaction.
pub fn share_screen_once(tokens: PathBuf) -> i32 {
    if !session_is_wayland() {
        println!("Not a Wayland session: nothing to share (X11 needs no approval).");
        return 0;
    }
    let Some(links) = Links::new(tokens) else {
        println!("This desktop has no screen-sharing portal with remote input; screenshots and x/y clicks will not work on Wayland.");
        return 1;
    };
    println!("Your desktop will ask you to share the screen with Computer Use Turbo (asked once).");
    println!("Turn on \"Allow Remote Interaction\", keep \"Remember This Selection\" ticked, and click Share.");
    match links.ensure(ASK_FOR + Duration::from_secs(5)) {
        Some(link) if link.input().is_some() => {
            println!("Screen shared and remembered: tasks will not ask again.");
            0
        }
        Some(_) => {
            println!("Shared without remote interaction: screenshots work, but clicks at x/y and key presses will not. Run this again and turn on \"Allow Remote Interaction\".");
            1
        }
        None => {
            println!("{}", links.note().unwrap_or_else(|| "The screen was not shared.".into()));
            1
        }
    }
}
