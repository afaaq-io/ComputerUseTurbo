//! X11 (and XWayland) side of the Linux helper: top-level windows and their processes,
//! window capture, focus, XTest input, and the user's own input (XInput2 raw events, so the
//! helper's XTest input is never mistaken for the user's).

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use image::RgbaImage;
use turbo_core::platform::Rect;
use x11rb::connection::Connection;
use x11rb::protocol::xinput::{self, ConnectionExt as _};
use x11rb::protocol::xproto::{
    self, AtomEnum, ClientMessageEvent, ConfigureWindowAux, ConnectionExt as _, EventMask, ImageFormat, InputFocus, MapState, StackMode,
};
use x11rb::protocol::xtest::ConnectionExt as _;
use x11rb::protocol::Event;
use x11rb::wrapper::ConnectionExt as _;
use x11rb::rust_connection::RustConnection;

pub struct Atoms {
    client_list: u32,
    active: u32,
    pid: u32,
    name: u32,
    utf8: u32,
}

fn atom(conn: &RustConnection, name: &str) -> u32 {
    conn.intern_atom(false, name.as_bytes()).ok().and_then(|c| c.reply().ok()).map(|r| r.atom).unwrap_or(0)
}

pub struct X11 {
    pub conn: RustConnection,
    pub root: u32,
    atoms: Atoms,
    keymap: Mutex<Option<(u8, u8, Vec<u32>)>>,
}

impl X11 {
    pub fn connect() -> Option<Self> {
        let (conn, screen) = RustConnection::connect(None).ok()?;
        let root = conn.setup().roots[screen].root;
        let atoms = Atoms {
            client_list: atom(&conn, "_NET_CLIENT_LIST"),
            active: atom(&conn, "_NET_ACTIVE_WINDOW"),
            pid: atom(&conn, "_NET_WM_PID"),
            name: atom(&conn, "_NET_WM_NAME"),
            utf8: atom(&conn, "UTF8_STRING"),
        };
        Some(Self { conn, root, atoms, keymap: Mutex::new(None) })
    }

    fn prop32(&self, win: u32, prop: u32, ty: AtomEnum) -> Vec<u32> {
        self.conn
            .get_property(false, win, prop, ty, 0, 4096)
            .ok()
            .and_then(|c| c.reply().ok())
            .and_then(|r| r.value32().map(|v| v.collect()))
            .unwrap_or_default()
    }

    pub fn pid_of(&self, win: u32) -> Option<u32> {
        self.prop32(win, self.atoms.pid, AtomEnum::CARDINAL).first().copied()
    }

    pub fn title(&self, win: u32) -> String {
        let read = |prop: u32, ty: u32| {
            self.conn
                .get_property(false, win, prop, ty, 0, 1024)
                .ok()
                .and_then(|c| c.reply().ok())
                .map(|r| String::from_utf8_lossy(&r.value).into_owned())
                .filter(|s| !s.is_empty())
        };
        read(self.atoms.name, self.atoms.utf8).or_else(|| read(AtomEnum::WM_NAME.into(), AtomEnum::STRING.into())).unwrap_or_default()
    }

    fn viewable(&self, win: u32) -> bool {
        self.conn
            .get_window_attributes(win)
            .ok()
            .and_then(|c| c.reply().ok())
            .is_some_and(|a| a.map_state == MapState::VIEWABLE)
    }

    /// Managed top-level windows (`_NET_CLIENT_LIST`), else the root's viewable children.
    pub fn top_levels(&self) -> Vec<u32> {
        let list = self.prop32(self.root, self.atoms.client_list, AtomEnum::WINDOW);
        if !list.is_empty() {
            return list.into_iter().filter(|w| self.viewable(*w)).collect();
        }
        let Some(tree) = self.conn.query_tree(self.root).ok().and_then(|c| c.reply().ok()) else { return vec![] };
        let mut out = vec![];
        for w in tree.children {
            if !self.viewable(w) {
                continue;
            }
            if self.pid_of(w).is_some() {
                out.push(w);
            } else if let Some(sub) = self.conn.query_tree(w).ok().and_then(|c| c.reply().ok()) {
                out.extend(sub.children.into_iter().filter(|c| self.pid_of(*c).is_some()));
            }
        }
        out
    }

    pub fn windows_of(&self, pid: u32) -> Vec<u32> {
        self.top_levels().into_iter().filter(|w| self.pid_of(*w) == Some(pid)).collect()
    }

    pub fn frame(&self, win: u32) -> Option<Rect> {
        let g = self.conn.get_geometry(win).ok()?.reply().ok()?;
        let t = self.conn.translate_coordinates(win, self.root, 0, 0).ok()?.reply().ok()?;
        Some(Rect { x: t.dst_x as f64, y: t.dst_y as f64, w: g.width as f64, h: g.height as f64 })
    }

    fn top_level_of(&self, mut win: u32) -> u32 {
        for _ in 0..16 {
            let Some(tree) = self.conn.query_tree(win).ok().and_then(|c| c.reply().ok()) else { break };
            if tree.parent == self.root || tree.parent == 0 {
                break;
            }
            if self.pid_of(win).is_some() {
                break;
            }
            win = tree.parent;
        }
        win
    }

    pub fn active_window(&self) -> Option<u32> {
        if let Some(w) = self.prop32(self.root, self.atoms.active, AtomEnum::WINDOW).first().copied().filter(|w| *w != 0) {
            return Some(w);
        }
        let focus = self.conn.get_input_focus().ok()?.reply().ok()?.focus;
        (focus > 1 && focus != self.root).then(|| self.top_level_of(focus))
    }

    pub fn active_pid(&self) -> Option<u32> {
        let w = self.active_window()?;
        self.pid_of(w).or_else(|| self.pid_of(self.top_level_of(w)))
    }

    /// The top-level window under a screen point.
    pub fn window_at(&self, x: i16, y: i16) -> Option<u32> {
        let mut win = self.root;
        for _ in 0..8 {
            let r = self.conn.translate_coordinates(self.root, win, x, y).ok()?.reply().ok()?;
            if r.child == 0 {
                break;
            }
            win = r.child;
            if self.pid_of(win).is_some() {
                return Some(win);
            }
        }
        (win != self.root).then_some(win)
    }

    pub fn activate(&self, win: u32) {
        if self.atoms.active != 0 && !self.prop32(self.root, self.atoms.client_list, AtomEnum::WINDOW).is_empty() {
            let ev = ClientMessageEvent::new(32, win, self.atoms.active, [2u32, x11rb::CURRENT_TIME, 0, 0, 0]);
            let _ = self.conn.send_event(false, self.root, EventMask::SUBSTRUCTURE_REDIRECT | EventMask::SUBSTRUCTURE_NOTIFY, ev);
        }
        let _ = self.conn.configure_window(win, &ConfigureWindowAux::new().stack_mode(StackMode::ABOVE));
        let _ = self.conn.set_input_focus(InputFocus::PARENT, win, x11rb::CURRENT_TIME);
        let _ = self.conn.flush();
    }

    pub fn capture(&self, win: u32) -> Option<RgbaImage> {
        let g = self.conn.get_geometry(win).ok()?.reply().ok()?;
        let img = self.conn.get_image(ImageFormat::Z_PIXMAP, win, 0, 0, g.width, g.height, !0).ok()?.reply().ok()?;
        let (w, h) = (g.width as u32, g.height as u32);
        let bpp = img.data.len() / (w as usize * h as usize).max(1);
        if bpp < 3 {
            return None;
        }
        let mut out = RgbaImage::new(w, h);
        for (i, px) in out.pixels_mut().enumerate() {
            let o = i * bpp;
            if o + 2 >= img.data.len() {
                break;
            }
            *px = image::Rgba([img.data[o + 2], img.data[o + 1], img.data[o], 255]);
        }
        Some(out)
    }

    // ---------------------------------------------------------------- XTest

    pub fn pointer(&self) -> Option<(i16, i16)> {
        let p = self.conn.query_pointer(self.root).ok()?.reply().ok()?;
        Some((p.root_x, p.root_y))
    }

    pub fn warp(&self, x: i16, y: i16) {
        let _ = self.conn.warp_pointer(x11rb::NONE, self.root, 0, 0, 0, 0, x, y);
        let _ = self.conn.flush();
    }

    fn fake(&self, ty: u8, detail: u8, x: i16, y: i16) {
        let _ = self.conn.xtest_fake_input(ty, detail, x11rb::CURRENT_TIME, self.root, x, y, 0);
        let _ = self.conn.flush();
    }

    pub fn motion(&self, x: i16, y: i16) {
        self.fake(xproto::MOTION_NOTIFY_EVENT, 0, x, y);
    }

    pub fn button(&self, button: u8, down: bool) {
        self.fake(if down { xproto::BUTTON_PRESS_EVENT } else { xproto::BUTTON_RELEASE_EVENT }, button, 0, 0);
    }

    pub fn key(&self, keycode: u8, down: bool) {
        self.fake(if down { xproto::KEY_PRESS_EVENT } else { xproto::KEY_RELEASE_EVENT }, keycode, 0, 0);
    }

    fn mapping(&self) -> Option<(u8, u8, Vec<u32>)> {
        let mut g = self.keymap.lock().unwrap();
        if g.is_none() {
            let setup = self.conn.setup();
            let (min, max) = (setup.min_keycode, setup.max_keycode);
            let r = self.conn.get_keyboard_mapping(min, max - min + 1).ok()?.reply().ok()?;
            *g = Some((min, r.keysyms_per_keycode, r.keysyms));
        }
        g.clone()
    }

    /// Keycode producing `keysym`, and whether Shift is needed.
    pub fn keycode_for(&self, keysym: u32) -> Option<(u8, bool)> {
        let (min, per, syms) = self.mapping()?;
        let per = per as usize;
        for (i, chunk) in syms.chunks(per).enumerate() {
            for (level, s) in chunk.iter().enumerate().take(2) {
                if *s == keysym {
                    return Some((min + i as u8, level == 1));
                }
            }
        }
        None
    }

    /// Press `keysym` once even if no key produces it: a spare keycode is mapped to it for
    /// the press and restored afterwards (Unicode characters).
    pub fn tap_keysym(&self, keysym: u32, extra_shift: bool) -> bool {
        let shift = self.keycode_for(0xffe1).map(|k| k.0);
        if let Some((code, need_shift)) = self.keycode_for(keysym) {
            let sh = need_shift || extra_shift;
            if sh {
                if let Some(s) = shift {
                    self.key(s, true);
                }
            }
            self.key(code, true);
            self.key(code, false);
            if sh {
                if let Some(s) = shift {
                    self.key(s, false);
                }
            }
            return true;
        }
        let Some((min, per, syms)) = self.mapping() else { return false };
        let per_us = per as usize;
        let Some(spare) = syms.chunks(per_us).position(|c| c.iter().all(|s| *s == 0)) else { return false };
        let code = min + spare as u8;
        let mut row = vec![0u32; per_us];
        row[0] = keysym;
        if per_us > 1 {
            row[1] = keysym;
        }
        let _ = self.conn.change_keyboard_mapping(1, code, per, &row);
        let _ = self.conn.sync();
        std::thread::sleep(Duration::from_millis(15));
        self.key(code, true);
        self.key(code, false);
        let _ = self.conn.sync();
        std::thread::sleep(Duration::from_millis(15));
        let _ = self.conn.change_keyboard_mapping(1, code, per, &vec![0u32; per_us]);
        let _ = self.conn.flush();
        true
    }
}

/// The user's own input, from XInput2 raw events (XTest devices ignored): when it last
/// happened, which app it was aimed at, and Esc presses.
pub struct InputMonitor {
    pub last_real: Mutex<Instant>,
    pub per_pid: Mutex<HashMap<u32, Instant>>,
}

impl InputMonitor {
    pub fn start(on_esc: Arc<dyn Fn() + Send + Sync>) -> Arc<Self> {
        let me = Arc::new(Self { last_real: Mutex::new(Instant::now() - Duration::from_secs(60)), per_pid: Mutex::new(HashMap::new()) });
        let m = me.clone();
        std::thread::Builder::new()
            .name("x11-input".into())
            .spawn(move || {
                if let Err(e) = m.run(on_esc) {
                    turbo_core::log::error(format!("input monitor stopped: {e}"));
                }
            })
            .ok();
        me
    }

    pub fn idle_seconds(&self) -> f64 {
        self.last_real.lock().unwrap().elapsed().as_secs_f64()
    }

    fn run(&self, on_esc: Arc<dyn Fn() + Send + Sync>) -> Result<(), Box<dyn std::error::Error>> {
        let x = X11::connect().ok_or("no X display")?;
        x.conn.xinput_xi_query_version(2, 2)?.reply()?;
        let devices = x.conn.xinput_xi_query_device(xinput::Device::ALL)?.reply()?;
        let xtest: Vec<u16> = devices
            .infos
            .iter()
            .filter(|d| String::from_utf8_lossy(&d.name).contains("XTEST"))
            .map(|d| d.deviceid)
            .collect();
        let mask = xinput::XIEventMask::RAW_KEY_PRESS | xinput::XIEventMask::RAW_BUTTON_PRESS | xinput::XIEventMask::RAW_MOTION;
        x.conn.xinput_xi_select_events(x.root, &[xinput::EventMask { deviceid: xinput::Device::ALL_MASTER.into(), mask: vec![mask] }])?;
        x.conn.flush()?;
        let escape = x.keycode_for(0xff1b).map(|k| k.0);
        loop {
            let ev = x.conn.wait_for_event()?;
            let (source, kind, detail) = match &ev {
                Event::XinputRawKeyPress(e) => (e.sourceid, 'k', e.detail),
                Event::XinputRawButtonPress(e) => (e.sourceid, 'b', e.detail),
                Event::XinputRawMotion(e) => (e.sourceid, 'm', 0),
                _ => continue,
            };
            if xtest.contains(&source) {
                continue;
            }
            *self.last_real.lock().unwrap() = Instant::now();
            match kind {
                'k' => {
                    if escape == Some(detail as u8) {
                        on_esc();
                    }
                    if let Some(pid) = x.active_pid() {
                        self.per_pid.lock().unwrap().insert(pid, Instant::now());
                    }
                }
                'b' => {
                    if let Some((px, py)) = x.pointer() {
                        if let Some(pid) = x.window_at(px, py).and_then(|w| x.pid_of(w)) {
                            self.per_pid.lock().unwrap().insert(pid, Instant::now());
                        }
                    }
                }
                _ => {}
            }
        }
    }
}

/// keysym of a character (Latin-1 directly, everything else as a Unicode keysym).
pub fn keysym_for_char(c: char) -> u32 {
    let u = c as u32;
    match c {
        '\n' => 0xff0d,
        '\t' => 0xff09,
        _ if (0x20..=0x7e).contains(&u) || (0xa0..=0xff).contains(&u) => u,
        _ => 0x0100_0000 + u,
    }
}
