//! The three helper windows, each run as its own small process (`--ui <mode>`) so the
//! service never blocks on a UI event loop:
//!   approval  the approval card; prints the choice and exits
//!   overlay   the status pill with Stop; reads states on stdin, prints `stop`
//!   preview   the live preview; reads frames on stdin

use std::io::{BufRead, Write};
use std::sync::mpsc::{channel, Receiver};
use std::time::{Duration, Instant};

use eframe::egui::{self, pos2, vec2, Color32, RichText, Rounding, Stroke, ViewportCommand};
use serde_json::Value;
use turbo_core::texts;

use super::theme::Palette;

/// Whether this process's windows are transparent (set by `ui::run`, which falls back to an
/// opaque window where OpenGL has no transparent configuration).
static TRANSPARENT: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(true);

pub fn set_transparent(t: bool) {
    TRANSPARENT.store(t, std::sync::atomic::Ordering::SeqCst);
}

fn transparent() -> bool {
    TRANSPARENT.load(std::sync::atomic::Ordering::SeqCst)
}

/// What shows behind the rounded panel: nothing, or the panel colour on an opaque window.
fn background(p: &Palette) -> [f32; 4] {
    if transparent() {
        [0.0; 4]
    } else {
        p.surface.to_normalized_gamma_f32()
    }
}

/// The next line from stdin, if one is waiting. One reader per process, shared by every
/// attempt (the opaque-window fallback keeps the lines that already arrived).
fn next_line() -> Option<String> {
    LINES.get_or_init(|| std::sync::Mutex::new(spawn_stdin_reader())).lock().unwrap().try_recv().ok()
}

static LINES: std::sync::OnceLock<std::sync::Mutex<Receiver<String>>> = std::sync::OnceLock::new();

/// Start reading stdin now, before any window exists: the helper must never wait on a
/// window that has not drawn yet (hidden windows may never draw).
pub fn start_reading_stdin() {
    LINES.get_or_init(|| std::sync::Mutex::new(spawn_stdin_reader()));
}

fn spawn_stdin_reader() -> Receiver<String> {
    let (tx, rx) = channel();
    std::thread::spawn(move || {
        for line in std::io::stdin().lock().lines() {
            match line {
                Ok(l) => {
                    if tx.send(l).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
        let _ = tx.send("{\"state\":\"quit\"}".into());
    });
    rx
}

/// Wayland lets no client place its windows or keep them above others, and hides the
/// keyboard from other clients (no Esc to stop).
fn wayland_session() -> bool {
    cfg!(target_os = "linux") && std::env::var("WAYLAND_DISPLAY").is_ok_and(|v| !v.is_empty())
}

/// An X11 display is reachable and winit's X11 keyboard library is installed.
#[cfg(target_os = "linux")]
fn x11_windows_available() -> bool {
    let lib_loads = ["libxkbcommon-x11.so.0", "libxkbcommon-x11.so"].iter().any(|name| {
        let c = std::ffi::CString::new(*name).unwrap();
        let h = unsafe { libc::dlopen(c.as_ptr(), libc::RTLD_LAZY) };
        !h.is_null() && unsafe { libc::dlclose(h) } == 0
    });
    lib_loads && x11rb::rust_connection::RustConnection::connect(None).is_ok()
}

static DRAWN: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

fn first_frame() {
    DRAWN.store(true, std::sync::atomic::Ordering::SeqCst);
}

/// Whether the window has drawn its first frame (the watchdog in `ui::run` waits for it).
pub fn drawn() -> bool {
    DRAWN.load(std::sync::atomic::Ordering::SeqCst)
}

fn base_options(size: [f32; 2], title: &str, active: bool) -> eframe::NativeOptions {
    // In a Wayland session with X11 compatibility, run as an X11 window: it may then sit at
    // the screen edge and stay on top, as everywhere else.
    #[cfg(target_os = "linux")]
    let event_loop_builder: Option<eframe::EventLoopBuilderHook> = (wayland_session() && x11_windows_available()).then(|| {
        Box::new(|b: &mut eframe::EventLoopBuilder<eframe::UserEvent>| {
            use winit::platform::x11::EventLoopBuilderExtX11;
            b.with_x11();
        }) as eframe::EventLoopBuilderHook
    });
    #[cfg(not(target_os = "linux"))]
    let event_loop_builder = None;
    eframe::NativeOptions {
        renderer: eframe::Renderer::Glow,
        event_loop_builder,
        viewport: egui::ViewportBuilder::default()
            .with_title(title)
            .with_inner_size(size)
            .with_decorations(false)
            .with_transparent(transparent())
            .with_always_on_top()
            .with_resizable(false)
            .with_taskbar(false)
            // X11 desktops list normal windows in their docks; these are helper panels.
            .with_window_type(egui::X11WindowType::Utility)
            .with_active(active),
        ..Default::default()
    }
}

/// Keep a helper window out of screenshots and recordings where the OS allows it.
#[allow(unused_variables)]
fn exclude_from_capture(frame: &eframe::Frame) {
    #[cfg(windows)]
    {
        use raw_window_handle::{HasWindowHandle, RawWindowHandle};
        use windows::Win32::Foundation::HWND;
        use windows::Win32::UI::WindowsAndMessaging::{SetWindowDisplayAffinity, WDA_EXCLUDEFROMCAPTURE};
        if let Ok(h) = frame.window_handle() {
            if let RawWindowHandle::Win32(w) = h.as_raw() {
                let hwnd = HWND(w.hwnd.get() as *mut _);
                unsafe {
                    let _ = SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);
                    // Opaque windows (Direct3D): let Windows 11 round the corners.
                    use windows::Win32::Graphics::Dwm::{DwmSetWindowAttribute, DWMWA_WINDOW_CORNER_PREFERENCE, DWMWCP_ROUND};
                    let round = DWMWCP_ROUND;
                    let _ = DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, &round as *const _ as *const _, std::mem::size_of_val(&round) as u32);
                }
            }
        }
    }
}

fn place(ctx: &egui::Context, placed: &mut bool, f: impl Fn(egui::Vec2) -> egui::Pos2) {
    if *placed {
        return;
    }
    if let Some(m) = ctx.input(|i| i.viewport().monitor_size) {
        if m.x > 0.0 {
            ctx.send_viewport_cmd(ViewportCommand::OuterPosition(f(m)));
            *placed = true;
        }
    }
}

// ------------------------------------------------------------------ approval

struct Approval {
    req: Value,
    palette: Palette,
    shown: Instant,
    placed: bool,
    focus_set: bool,
    done: bool,
    size: [f32; 2],
    excluded: bool,
}

const ARM_DELAY: Duration = Duration::from_millis(750);

impl Approval {
    fn finish(&mut self, ctx: &egui::Context, choice: &str) {
        if self.done {
            return;
        }
        self.done = true;
        let mut out = std::io::stdout().lock();
        let _ = writeln!(out, "{choice}");
        let _ = out.flush();
        ctx.send_viewport_cmd(ViewportCommand::Close);
    }

    fn s(&self, key: &str) -> String {
        self.req.get(key).and_then(Value::as_str).unwrap_or("").to_string()
    }
}

impl eframe::App for Approval {
    fn clear_color(&self, _: &egui::Visuals) -> [f32; 4] {
        background(&self.palette)
    }

    fn update(&mut self, ctx: &egui::Context, frame: &mut eframe::Frame) {
        first_frame();
        if !self.excluded {
            exclude_from_capture(frame);
            self.excluded = true;
        }
        let size = self.size;
        place(ctx, &mut self.placed, |m| pos2(((m.x - size[0]) / 2.0).max(0.0), ((m.y - size[1]) / 2.5).max(0.0)));
        let timeout = self.req.get("timeoutSecs").and_then(Value::as_u64).unwrap_or(120);
        if self.shown.elapsed() > Duration::from_secs(timeout) || ctx.input(|i| i.key_pressed(egui::Key::Escape)) {
            self.finish(ctx, "deny");
            return;
        }
        let armed = self.shown.elapsed() >= ARM_DELAY;
        if !armed {
            ctx.request_repaint_after(ARM_DELAY.saturating_sub(self.shown.elapsed()));
        } else {
            ctx.request_repaint_after(Duration::from_millis(500));
        }
        let p = self.palette.clone();
        let agent = self.s("agent");
        let app = self.s("appName");
        let mut choice: Option<&str> = None;
        egui::CentralPanel::default()
            .frame(egui::Frame::none().fill(p.surface).stroke(Stroke::new(1.0_f32, p.border)).rounding(Rounding::same(18.0)).inner_margin(20.0))
            .show(ctx, |ui| {
                ui.spacing_mut().item_spacing = vec2(8.0, 6.0);
                ui.horizontal(|ui| {
                    let (rect, _) = ui.allocate_exact_size(vec2(40.0, 40.0), egui::Sense::hover());
                    ui.painter().rect_filled(rect, 10.0, p.primary_fill);
                    let initial = app.chars().next().map(|c| c.to_uppercase().to_string()).unwrap_or_default();
                    ui.painter().text(rect.center(), egui::Align2::CENTER_CENTER, initial, egui::FontId::proportional(20.0), p.primary_text);
                    ui.vertical(|ui| {
                        ui.label(RichText::new(texts::approval_title(&agent, &app)).size(15.0).strong().color(p.text));
                        ui.label(RichText::new(texts::APPROVAL_SUBTITLE).size(12.0).color(p.text_secondary));
                    });
                });
                ui.add_space(10.0);
                ui.label(RichText::new(texts::approval_intro(&agent)).size(13.0).strong().color(p.text));
                for b in texts::approval_bullets(&app) {
                    ui.label(RichText::new(format!("•  {b}")).size(13.0).color(p.text_secondary));
                }
                ui.add_space(4.0);
                ui.label(RichText::new(format!("⚠  {}", texts::approval_sensitive(&agent, &app))).size(12.0).color(p.warning));
                ui.add_space(4.0);
                ui.label(RichText::new(format!("{}  ·  {}", texts::APPROVAL_STOP_HINT, self.s("appId"))).size(11.0).color(p.text_tertiary));
                ui.add_space(10.0);
                let w = ui.available_width();
                let primary = egui::Button::new(RichText::new(texts::BUTTON_SESSION).size(13.0).color(p.primary_text))
                    .fill(p.primary_fill)
                    .rounding(10.0);
                if ui.add_enabled_ui(armed, |ui| ui.add_sized([w, 34.0], primary)).inner.clicked() {
                    choice = Some("session");
                }
                let once = egui::Button::new(RichText::new(texts::BUTTON_ONCE).size(13.0).color(p.button_text))
                    .fill(p.button_fill)
                    .stroke(Stroke::new(1.0_f32, p.button_border))
                    .rounding(10.0)
                    .min_size(vec2(w, 34.0));
                if ui.add_enabled(armed, once).clicked() {
                    choice = Some("once");
                }
                let deny = ui.add_sized(
                    [w, 30.0],
                    egui::Button::new(RichText::new(texts::BUTTON_DENY).size(13.0).color(p.text_button)).fill(Color32::TRANSPARENT),
                );
                if !self.focus_set {
                    deny.request_focus();
                    self.focus_set = true;
                }
                if deny.clicked() {
                    choice = Some("deny");
                }
            });
        if let Some(c) = choice {
            self.finish(ctx, c);
        }
    }
}

pub fn run_approval(json: &str) -> eframe::Result<()> {
    let req: Value = serde_json::from_str(json).unwrap_or(Value::Null);
    let size = [380.0, 400.0];
    let title = texts::approval_title(req.get("agent").and_then(Value::as_str).unwrap_or(""), req.get("appName").and_then(Value::as_str).unwrap_or(""));
    eframe::run_native(
        &title,
        base_options(size, &title, true),
        Box::new(move |_cc| {
            Ok(Box::new(Approval {
                req,
                palette: Palette::current(),
                shown: Instant::now(),
                placed: false,
                focus_set: false,
                done: false,
                size,
                excluded: false,
            }))
        }),
    )
}

// ------------------------------------------------------------------ overlay

struct Overlay {
    text: String,
    stopped: bool,
    visible: bool,
    placed: bool,
    palette: Palette,
    started: Instant,
    excluded: bool,
}

const OVERLAY_SIZE: [f32; 2] = [400.0, 42.0];

impl eframe::App for Overlay {
    fn clear_color(&self, _: &egui::Visuals) -> [f32; 4] {
        background(&self.palette)
    }

    fn update(&mut self, ctx: &egui::Context, frame: &mut eframe::Frame) {
        first_frame();
        if !self.excluded {
            exclude_from_capture(frame);
            self.excluded = true;
        }
        while let Some(line) = next_line() {
            let v: Value = serde_json::from_str(&line).unwrap_or(Value::Null);
            match v.get("state").and_then(Value::as_str) {
                Some("active") => {
                    self.text = texts::overlay_using(v["agent"].as_str().unwrap_or(""), v["app"].as_str().unwrap_or(""));
                    self.stopped = false;
                    if !self.visible {
                        self.visible = true;
                        ctx.send_viewport_cmd(ViewportCommand::Visible(true));
                    }
                }
                Some("stopped") => {
                    self.text = texts::OVERLAY_STOPPED.into();
                    self.stopped = true;
                }
                Some("hidden") => {
                    self.visible = false;
                    ctx.send_viewport_cmd(ViewportCommand::Visible(false));
                }
                Some("quit") => ctx.send_viewport_cmd(ViewportCommand::Close),
                _ => {}
            }
        }
        place(ctx, &mut self.placed, |m| pos2(m.x - OVERLAY_SIZE[0] - 16.0, 12.0));
        ctx.request_repaint_after(Duration::from_millis(60));
        let p = self.palette.clone();
        egui::CentralPanel::default()
            .frame(egui::Frame::none().fill(p.surface).stroke(Stroke::new(1.0_f32, p.border)).rounding(Rounding::same(21.0)).inner_margin(egui::Margin { left: 14.0, right: 7.0, top: 7.0, bottom: 7.0 }))
            .show(ctx, |ui| {
                ui.horizontal_centered(|ui| {
                    let (rect, _) = ui.allocate_exact_size(vec2(14.0, 14.0), egui::Sense::hover());
                    let c = rect.center();
                    if self.stopped {
                        ui.painter().circle_filled(c, 4.0, p.dot_stopped);
                    } else {
                        let t = (self.started.elapsed().as_secs_f32() % 1.6) / 1.6;
                        let halo = p.dot.gamma_multiply(0.55 * (1.0 - t));
                        ui.painter().circle_filled(c, 4.0 + 6.4 * t, halo);
                        ui.painter().circle_filled(c, 4.0, p.dot);
                    }
                    ui.add_space(6.0);
                    // Leave room for the Stop capsule; long names are cut with "…".
                    let room = (ui.available_width() - 104.0).max(40.0);
                    ui.allocate_ui(vec2(room, 24.0), |ui| {
                        ui.add(egui::Label::new(RichText::new(&self.text).size(13.0).color(p.text)).truncate());
                    });
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        let label = if wayland_session() { "■  Stop" } else { "■  Stop   esc" };
                        let stop = egui::Button::new(RichText::new(label).size(12.0).color(p.stop_text))
                            .fill(p.stop_fill)
                            .stroke(Stroke::new(1.0_f32, p.stop_border))
                            .rounding(13.0);
                        if ui.add_enabled(!self.stopped, stop).clicked() {
                            let mut out = std::io::stdout().lock();
                            let _ = writeln!(out, "stop");
                            let _ = out.flush();
                        }
                    });
                });
            });
    }
}

pub fn run_overlay() -> eframe::Result<()> {
    eframe::run_native(
        "Computer Use Turbo status",
        {
            let mut o = base_options(OVERLAY_SIZE, "Computer Use Turbo status", false);
            o.viewport = o.viewport.with_window_type(egui::X11WindowType::Notification);
            o
        },
        Box::new(move |_cc| {
            Ok(Box::new(Overlay {
                text: String::new(),
                stopped: false,
                visible: true,
                placed: false,
                palette: Palette::current(),
                started: Instant::now(),
                excluded: false,
            }))
        }),
    )
}

// ------------------------------------------------------------------ preview

struct Preview {
    texture: Option<egui::TextureHandle>,
    aspect: f32,
    anchor: Option<[f32; 4]>,
    last_pos: Option<egui::Pos2>,
    visible: bool,
    palette: Palette,
    excluded: bool,
}

const PREVIEW_W: f32 = 320.0;

impl eframe::App for Preview {
    fn clear_color(&self, _: &egui::Visuals) -> [f32; 4] {
        background(&self.palette)
    }

    fn update(&mut self, ctx: &egui::Context, frame: &mut eframe::Frame) {
        first_frame();
        if !self.excluded {
            exclude_from_capture(frame);
            self.excluded = true;
        }
        let mut latest: Option<Value> = None;
        while let Some(line) = next_line() {
            let v: Value = serde_json::from_str(&line).unwrap_or(Value::Null);
            match v.get("cmd").and_then(Value::as_str) {
                Some("frame") => latest = Some(v),
                Some("hide") => {
                    latest = None;
                    if self.visible {
                        self.visible = false;
                        ctx.send_viewport_cmd(ViewportCommand::Visible(false));
                    }
                }
                Some("quit") => ctx.send_viewport_cmd(ViewportCommand::Close),
                _ => {}
            }
        }
        if let Some(v) = latest {
            if let Some(bytes) = v.get("jpeg").and_then(Value::as_str).and_then(turbo_core::b64::decode) {
                if let Ok(img) = image::load_from_memory(&bytes) {
                    let rgba = img.to_rgba8();
                    let (w, h) = rgba.dimensions();
                    self.aspect = w as f32 / h.max(1) as f32;
                    let ci = egui::ColorImage::from_rgba_unmultiplied([w as usize, h as usize], rgba.as_raw());
                    match &mut self.texture {
                        Some(t) => t.set(ci, egui::TextureOptions::LINEAR),
                        None => self.texture = Some(ctx.load_texture("preview", ci, egui::TextureOptions::LINEAR)),
                    }
                }
            }
            self.anchor = v.get("anchor").and_then(Value::as_array).and_then(|a| {
                let f: Vec<f32> = a.iter().filter_map(Value::as_f64).map(|x| x as f32).collect();
                (f.len() == 4).then(|| [f[0], f[1], f[2], f[3]])
            });
            if !self.visible {
                self.visible = true;
                ctx.send_viewport_cmd(ViewportCommand::Visible(true));
            }
        }
        let image_h = (PREVIEW_W / self.aspect.max(0.2)).clamp(120.0, 240.0);
        let size = vec2(PREVIEW_W, image_h);
        ctx.send_viewport_cmd(ViewportCommand::InnerSize(size));
        let monitor = ctx.input(|i| i.viewport().monitor_size).unwrap_or(vec2(1920.0, 1080.0));
        let pos = match self.anchor {
            Some([x, y, w, _]) => pos2((x + w - 16.0 - PREVIEW_W).max(0.0), y + 56.0),
            None => pos2(monitor.x - PREVIEW_W - 16.0, 64.0),
        };
        if self.last_pos != Some(pos) {
            ctx.send_viewport_cmd(ViewportCommand::OuterPosition(pos));
            self.last_pos = Some(pos);
        }
        let p = self.palette.clone();
        egui::CentralPanel::default()
            .frame(egui::Frame::none().fill(p.preview_bg).stroke(Stroke::new(1.0_f32, p.border)).rounding(Rounding::same(12.0)).inner_margin(3.0))
            .show(ctx, |ui| {
                if let Some(t) = &self.texture {
                    let avail = ui.available_size();
                    ui.add(egui::Image::new((t.id(), avail)).rounding(9.0));
                }
            });
        ctx.request_repaint_after(Duration::from_millis(100));
    }
}

pub fn run_preview() -> eframe::Result<()> {
    eframe::run_native(
        "Computer Use Turbo live preview",
        base_options([PREVIEW_W, 200.0], "Computer Use Turbo live preview", false),
        Box::new(move |_cc| {
            Ok(Box::new(Preview {
                texture: None,
                aspect: 16.0 / 10.0,
                anchor: None,
                last_pos: None,
                visible: true,
                palette: Palette::current(),
                excluded: false,
            }))
        }),
    )
}
