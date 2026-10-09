//! Real input on Wayland through the portal's EIS socket (libei protocol, spoken by `reis`).
//! The compositor gives us virtual devices: an absolute pointer whose region is the shared
//! window's stream (so a screenshot pixel is a pointer position), buttons, scrolling and a
//! keyboard with its keymap. Events are read on a thread of our own (the compositor pings).

use std::collections::HashMap;
use std::os::fd::{AsFd, OwnedFd};
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use reis::ei;
use reis::event::{Device, DeviceCapability, EiEvent, EiEventConverter};
use xkbcommon::xkb;

#[derive(Default)]
struct State {
    devices: Vec<(Device, bool)>,
    /// keysym → (evdev key code, needs Shift)
    keys: HashMap<u32, (u32, bool)>,
    sequence: u32,
}

pub struct Eis {
    ctx: ei::Context,
    conn: Mutex<Option<reis::event::Connection>>,
    state: Mutex<State>,
    changed: Condvar,
    pub alive: AtomicBool,
    /// When we last sent input (so our own input is not taken for the user's).
    pub last_sent: Mutex<Option<Instant>>,
}

pub const BTN_LEFT: u32 = 0x110;
pub const BTN_RIGHT: u32 = 0x111;
pub const BTN_MIDDLE: u32 = 0x112;

fn now_us() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_micros() as u64).unwrap_or(0)
}

impl Eis {
    pub fn connect(fd: OwnedFd) -> Option<Arc<Self>> {
        let ctx = ei::Context::new(UnixStream::from(fd)).ok()?;
        let me = Arc::new(Self { ctx, conn: Mutex::new(None), state: Mutex::new(State::default()), changed: Condvar::new(), alive: AtomicBool::new(true), last_sent: Mutex::new(None) });
        let m = me.clone();
        // The handshake and the event converter live on the reading thread.
        std::thread::Builder::new()
            .name("eis".into())
            .spawn(move || match reis::handshake::ei_handshake_blocking(&m.ctx, "computer-use-turbo", ei::handshake::ContextType::Sender) {
                Ok(resp) => {
                    let converter = EiEventConverter::new(&m.ctx, resp);
                    *m.conn.lock().unwrap() = Some(converter.connection().clone());
                    m.read_loop(converter);
                }
                Err(e) => {
                    turbo_core::log::error(format!("EIS handshake failed: {e:?}"));
                    m.alive.store(false, Ordering::SeqCst);
                    m.changed.notify_all();
                }
            })
            .ok()?;
        // Devices arrive right after the seat is bound.
        let until = Instant::now() + Duration::from_secs(3);
        let mut g = me.state.lock().unwrap();
        while me.alive.load(Ordering::SeqCst) && !g.devices.iter().any(|(d, on)| *on && d.has_capability(DeviceCapability::PointerAbsolute)) {
            let Some(left) = until.checked_duration_since(Instant::now()) else { break };
            g = me.changed.wait_timeout(g, left).ok()?.0;
        }
        drop(g);
        Some(me)
    }

    fn read_loop(&self, mut converter: EiEventConverter) {
        loop {
            let fd = self.ctx.as_fd();
            let mut fds = [rustix::event::PollFd::new(&fd, rustix::event::PollFlags::IN)];
            let _ = rustix::event::poll(&mut fds, Some(&rustix::time::Timespec { tv_sec: 0, tv_nsec: 250_000_000 }));
            if !fds[0].revents().is_empty() {
                match self.ctx.read() {
                    Ok(0) => break,
                    Err(e) if e.kind() != std::io::ErrorKind::WouldBlock => break,
                    _ => {}
                }
            }
            while let Some(pending) = self.ctx.pending_event() {
                if let reis::PendingRequestResult::Request(ev) = pending {
                    if converter.handle_event(ev).is_err() {
                        break;
                    }
                }
            }
            while let Some(ev) = converter.next_event() {
                let mut st = self.state.lock().unwrap();
                match ev {
                    EiEvent::SeatAdded(s) => {
                        s.seat.bind_capabilities(DeviceCapability::PointerAbsolute | DeviceCapability::Button | DeviceCapability::Scroll | DeviceCapability::Keyboard);
                    }
                    EiEvent::DeviceAdded(d) => {
                        if let Some(km) = d.device.keymap() {
                            if let Ok(fd) = km.fd.try_clone() {
                                st.keys = keymap_table(fd, km.size);
                            }
                        }
                        st.devices.push((d.device, false));
                    }
                    EiEvent::DeviceResumed(d) => st.devices.iter_mut().filter(|(x, _)| *x == d.device).for_each(|e| e.1 = true),
                    EiEvent::DevicePaused(d) => st.devices.iter_mut().filter(|(x, _)| *x == d.device).for_each(|e| e.1 = false),
                    EiEvent::DeviceRemoved(d) => st.devices.retain(|(x, _)| *x != d.device),
                    EiEvent::Disconnected(_) => {
                        self.alive.store(false, Ordering::SeqCst);
                    }
                    _ => {}
                }
                self.changed.notify_all();
            }
            self.flush();
            if !self.alive.load(Ordering::SeqCst) {
                break;
            }
        }
        self.alive.store(false, Ordering::SeqCst);
        self.changed.notify_all();
    }

    fn flush(&self) {
        if let Some(c) = self.conn.lock().unwrap().as_ref() {
            let _ = c.flush();
        }
    }

    fn serial(&self) -> u32 {
        self.conn.lock().unwrap().as_ref().map_or(0, |c| c.serial())
    }

    fn device(&self, cap: DeviceCapability) -> Option<Device> {
        self.state.lock().unwrap().devices.iter().find(|(d, on)| *on && d.has_capability(cap)).map(|(d, _)| d.clone())
    }

    /// Run `f` between start/stop emulating on `dev`, then flush.
    fn emulate(&self, dev: &Device, f: impl FnOnce(&Device, u32)) {
        let serial = self.serial();
        let seq = {
            let mut st = self.state.lock().unwrap();
            st.sequence = st.sequence.wrapping_add(1);
            st.sequence
        };
        dev.device().start_emulating(serial, seq);
        f(dev, serial);
        dev.device().stop_emulating(serial);
        self.flush();
        *self.last_sent.lock().unwrap() = Some(Instant::now());
    }

    /// A point → absolute pointer position: desktop coordinates as they are (no mapping), or
    /// a stream point offset by the region whose mapping id is that stream's.
    fn position(dev: &Device, mapping: Option<&str>, x: f64, y: f64) -> (f32, f32) {
        if mapping.is_none() {
            return (x as f32, y as f32);
        }
        let regions = dev.regions();
        let r = regions.iter().find(|r| mapping.is_some() && r.mapping_id.as_deref() == mapping).or(regions.first());
        let (ox, oy) = r.map_or((0.0, 0.0), |r| (r.x as f64, r.y as f64));
        ((ox + x) as f32, (oy + y) as f32)
    }


    pub fn move_to(&self, mapping: Option<&str>, x: f64, y: f64) -> bool {
        let Some(dev) = self.device(DeviceCapability::PointerAbsolute) else { return false };
        self.emulate(&dev, |d, serial| {
            if let Some(p) = d.interface::<ei::PointerAbsolute>() {
                let (px, py) = Self::position(d, mapping, x, y);
                p.motion_absolute(px, py);
                d.device().frame(serial, now_us());
            }
        });
        true
    }

    pub fn button(&self, code: u32, down: bool) -> bool {
        let Some(dev) = self.device(DeviceCapability::Button) else { return false };
        self.emulate(&dev, |d, serial| {
            if let Some(b) = d.interface::<ei::Button>() {
                b.button(code, if down { ei::button::ButtonState::Press } else { ei::button::ButtonState::Released });
                d.device().frame(serial, now_us());
            }
        });
        true
    }

    pub fn click(&self, mapping: Option<&str>, x: f64, y: f64, code: u32, times: u8) -> bool {
        if !self.move_to(mapping, x, y) {
            return false;
        }
        // Toolkits drop a press that arrives together with the pointer entering the window.
        std::thread::sleep(Duration::from_millis(90));
        for _ in 0..times.max(1) {
            self.button(code, true);
            std::thread::sleep(Duration::from_millis(40));
            self.button(code, false);
            std::thread::sleep(Duration::from_millis(60));
        }
        std::thread::sleep(Duration::from_millis(60));
        true
    }

    /// Discrete scrolling at a point: `dx`/`dy` in wheel notches (positive = right / down).
    pub fn scroll(&self, mapping: Option<&str>, x: f64, y: f64, dx: i32, dy: i32) -> bool {
        if !self.move_to(mapping, x, y) {
            return false;
        }
        let Some(dev) = self.device(DeviceCapability::Scroll) else { return false };
        self.emulate(&dev, |d, serial| {
            if let Some(s) = d.interface::<ei::Scroll>() {
                s.scroll_discrete(dx * 120, dy * 120);
                d.device().frame(serial, now_us());
                s.scroll_stop(1, 1, 0);
                d.device().frame(serial, now_us());
            }
        });
        true
    }

    fn key(&self, dev: &Device, code: u32, down: bool) {
        self.emulate(dev, |d, serial| {
            if let Some(k) = d.interface::<ei::Keyboard>() {
                k.key(code, if down { ei::keyboard::KeyState::Press } else { ei::keyboard::KeyState::Released });
                d.device().frame(serial, now_us());
            }
        });
    }

    fn code_for(&self, keysym: u32) -> Option<(u32, bool)> {
        self.state.lock().unwrap().keys.get(&keysym).copied()
    }


    /// Press `keysym` with the modifier keysyms held. False when the keymap has no such key.
    pub fn chord(&self, modifiers: &[u32], keysym: u32, extra_shift: bool) -> bool {
        let Some(dev) = self.device(DeviceCapability::Keyboard) else { return false };
        let Some((code, needs_shift)) = self.code_for(keysym).or_else(|| self.code_for(lower(keysym)).map(|(c, _)| (c, true))) else { return false };
        let mut held = vec![];
        for m in modifiers {
            if let Some((c, _)) = self.code_for(*m) {
                self.key(&dev, c, true);
                held.push(c);
            }
        }
        let shift = if (needs_shift || extra_shift) && !modifiers.contains(&SHIFT) { self.code_for(SHIFT).map(|s| s.0) } else { None };
        if let Some(s) = shift {
            self.key(&dev, s, true);
        }
        self.key(&dev, code, true);
        std::thread::sleep(Duration::from_millis(20));
        self.key(&dev, code, false);
        if let Some(s) = shift {
            self.key(&dev, s, false);
        }
        for c in held.into_iter().rev() {
            self.key(&dev, c, false);
        }
        std::thread::sleep(Duration::from_millis(30));
        true
    }

    /// Alt+Tab with Tab pressed `steps` times while Alt is held (the desktop's own window
    /// switcher: the only way to bring another app forward on Wayland).
    pub fn alt_tab(&self, steps: usize) -> bool {
        const ALT_L: u32 = 0xffe9;
        const TAB: u32 = 0xff09;
        let Some(dev) = self.device(DeviceCapability::Keyboard) else { return false };
        let (Some((alt, _)), Some((tab, _))) = (self.code_for(ALT_L), self.code_for(TAB)) else { return false };
        self.key(&dev, alt, true);
        std::thread::sleep(Duration::from_millis(60));
        for _ in 0..steps.max(1) {
            self.key(&dev, tab, true);
            std::thread::sleep(Duration::from_millis(30));
            self.key(&dev, tab, false);
            std::thread::sleep(Duration::from_millis(90));
        }
        self.key(&dev, alt, false);
        true
    }

    /// Type `text` as key presses. Stops at a character the keyboard layout cannot produce:
    /// Err(characters typed so far, the character).
    pub fn type_text(&self, text: &str, interrupted: &dyn Fn() -> bool) -> Result<usize, (usize, Option<char>)> {
        let mut n = 0;
        for c in text.chars() {
            if interrupted() {
                return Err((n, None));
            }
            if !self.chord(&[], super::x11::keysym_for_char(c), false) {
                return Err((n, Some(c)));
            }
            n += 1;
            std::thread::sleep(Duration::from_millis(8));
        }
        Ok(n)
    }
}

pub const SHIFT: u32 = 0xffe1;

/// Upper-case Latin keysym → its lower-case key (typed with Shift).
fn lower(keysym: u32) -> u32 {
    if (0x41..=0x5a).contains(&keysym) {
        keysym + 0x20
    } else {
        keysym
    }
}

/// keysym → (evdev code, Shift needed) for the first layout's plain and shifted levels.
fn keymap_table(fd: OwnedFd, size: u32) -> HashMap<u32, (u32, bool)> {
    let mut out = HashMap::new();
    // The keymap is text in shared memory; read it from the start.
    use std::os::unix::fs::FileExt;
    let mut buf = vec![0u8; size.min(4 << 20) as usize];
    if std::fs::File::from(fd).read_exact_at(&mut buf, 0).is_err() {
        return out;
    }
    let text = String::from_utf8_lossy(&buf).trim_end_matches('\0').to_string();
    let ctx = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);
    let Some(keymap) = xkb::Keymap::new_from_string(&ctx, text, xkb::KEYMAP_FORMAT_TEXT_V1, xkb::COMPILE_NO_FLAGS) else {
        return out;
    };
    let (min, max) = (keymap.min_keycode().raw(), keymap.max_keycode().raw());
    for level in 0..2u32 {
        for code in min..=max {
            for sym in keymap.key_get_syms_by_level(xkb::Keycode::new(code), 0, level) {
                out.entry(sym.raw()).or_insert((code.saturating_sub(8), level == 1));
            }
        }
    }
    out
}
