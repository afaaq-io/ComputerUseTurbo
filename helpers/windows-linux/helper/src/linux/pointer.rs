//! The agent pointer on Linux: a small 32-bit (ARGB) X11 window that
//! bypasses the window manager, ignores the mouse (empty input shape) and is drawn in
//! software. X11 desktops and XWayland apps get it; it needs a compositing manager for the
//! transparency (every current desktop has one), so without one there is no pointer. Native
//! Wayland windows get none: their position on screen is not known to other clients.

use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::Mutex;
use std::time::Duration;

use x11rb::connection::Connection;
use x11rb::protocol::shape::{self, ConnectionExt as _};
use x11rb::protocol::xproto::{
    ClipOrdering, ColormapAlloc, ConfigureWindowAux, ConnectionExt as _, CreateGCAux, CreateWindowAux, ImageFormat, StackMode, VisualClass, WindowClass,
};
use x11rb::rust_connection::RustConnection;

use crate::pointer_art::{self, Cmd, Glide};

pub struct Pointer {
    tx: Mutex<Option<Sender<(Cmd, Option<Glide>)>>>,
    pos: Mutex<Option<(f64, f64)>>,
    /// The window could not be created here (no X display, no 32-bit visual, no compositor).
    unavailable: std::sync::atomic::AtomicBool,
}

impl Pointer {
    pub fn new() -> Self {
        Self { tx: Mutex::new(None), pos: Mutex::new(None), unavailable: Default::default() }
    }

    fn send(&self, cmd: Cmd, glide: Option<Glide>) -> bool {
        let mut g = self.tx.lock().unwrap();
        if g.is_none() {
            let Some(win) = Win::create() else {
                self.unavailable.store(true, std::sync::atomic::Ordering::SeqCst);
                return false;
            };
            let (tx, rx) = channel();
            std::thread::Builder::new().name("agent-pointer".into()).spawn(move || run(win, rx)).ok();
            *g = Some(tx);
        }
        g.as_ref().is_some_and(|tx| tx.send((cmd, glide)).is_ok())
    }

    /// Glide to (x, y) (X root coordinates); None when there is no pointer here.
    pub fn glide(&self, x: f64, y: f64, show: bool, speed: f64) -> Option<Duration> {
        if self.unavailable.load(std::sync::atomic::Ordering::SeqCst) {
            return None;
        }
        let mut pos = self.pos.lock().unwrap();
        let first = pos.is_none();
        let glide = Glide::new(pos.unwrap_or((x, y)), (x, y), speed, 1.0);
        let d = glide.duration.max(if first { Duration::from_millis(200) } else { Duration::ZERO });
        *pos = Some((x, y));
        drop(pos);
        self.send(Cmd::Glide { show }, Some(glide)).then_some(d)
    }

    pub fn click(&self) {
        if self.tx.lock().unwrap().is_some() {
            self.send(Cmd::Click, None);
        }
    }

    pub fn hide(&self) {
        *self.pos.lock().unwrap() = None;
        if self.tx.lock().unwrap().is_some() {
            self.send(Cmd::Hide, None);
        }
    }
}

struct Win {
    conn: RustConnection,
    win: u32,
    gc: u32,
    size: u32,
}

impl Win {
    fn create() -> Option<Self> {
        let (conn, screen_num) = RustConnection::connect(None).ok()?;
        let screen = conn.setup().roots[screen_num].clone();
        // Transparency needs a compositing manager (a Wayland compositor always composites
        // XWayland windows).
        let cm = conn.intern_atom(false, format!("_NET_WM_CM_S{screen_num}").as_bytes()).ok()?.reply().ok()?.atom;
        let wayland = std::env::var_os("WAYLAND_DISPLAY").is_some();
        if !wayland && conn.get_selection_owner(cm).ok()?.reply().ok()?.owner == x11rb::NONE {
            turbo_core::log::info("agent pointer: no compositing manager, so no pointer");
            return None;
        }
        let visual = screen
            .allowed_depths
            .iter()
            .filter(|d| d.depth == 32)
            .flat_map(|d| d.visuals.iter())
            .find(|v| v.class == VisualClass::TRUE_COLOR)?
            .visual_id;
        let size = pointer_art::CANVAS_PT as u32;
        let colormap = conn.generate_id().ok()?;
        conn.create_colormap(ColormapAlloc::NONE, colormap, screen.root, visual).ok()?;
        let win = conn.generate_id().ok()?;
        conn.create_window(
            32,
            win,
            screen.root,
            0,
            0,
            size as u16,
            size as u16,
            0,
            WindowClass::INPUT_OUTPUT,
            visual,
            &CreateWindowAux::new().override_redirect(1).background_pixel(0).border_pixel(0).colormap(colormap),
        )
        .ok()?;
        // No input region: clicks go through to whatever is underneath.
        conn.shape_rectangles(shape::SO::SET, shape::SK::INPUT, ClipOrdering::UNSORTED, win, 0, 0, &[]).ok()?;
        let gc = conn.generate_id().ok()?;
        conn.create_gc(gc, win, &CreateGCAux::new()).ok()?;
        conn.flush().ok()?;
        Some(Self { conn, win, gc, size })
    }

    fn show(&self, on: bool) {
        if on {
            let _ = self.conn.map_window(self.win);
        } else {
            let _ = self.conn.unmap_window(self.win);
        }
        let _ = self.conn.flush();
    }

    fn draw(&self, rgba: &[u8], at: (f64, f64)) {
        // Premultiplied RGBA → the ARGB visual's B, G, R, A bytes.
        let bgra: Vec<u8> = rgba.chunks_exact(4).flat_map(|c| [c[2], c[1], c[0], c[3]]).collect();
        let half = self.size as i32 / 2;
        let _ = self.conn.configure_window(
            self.win,
            &ConfigureWindowAux::new().x(at.0.round() as i32 - half).y(at.1.round() as i32 - half).stack_mode(StackMode::ABOVE),
        );
        let _ = self.conn.put_image(ImageFormat::Z_PIXMAP, self.win, self.gc, self.size as u16, self.size as u16, 0, 0, 0, 32, &bgra);
        let _ = self.conn.flush();
    }
}

fn run(win: Win, rx: Receiver<(Cmd, Option<Glide>)>) {
    pointer_art::animate(
        rx,
        |on| win.show(on),
        |pos, press, ring, alpha| {
            if let Some((rgba, _)) = pointer_art::render(1.0, press, ring, alpha) {
                win.draw(&rgba, pos);
            }
        },
        || {},
    );
}
