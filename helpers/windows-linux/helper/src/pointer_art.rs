//! The agent pointer's look and motion, shared by the Windows and Linux
//! windows that show it: a rounded clay arrow drawn in software (no GPU needed), gliding
//! along a slightly curved path with ease-in-out, a press and an expanding ring on clicks.

use std::time::{Duration, Instant};

use tiny_skia::{Color, FillRule, Paint, PathBuilder, Pixmap, Stroke, Transform};

/// The canvas is a square of this many points with the arrow's tip at its centre, so the
/// click ring (up to 40 pt) fits around the tip.
pub const CANVAS_PT: f32 = 96.0;
const TIP: (f32, f32) = (3.2, 2.6);
const CLAY: (u8, u8, u8) = (0xD9, 0x77, 0x57);
pub const RING_MS: u64 = 450;

fn arrow() -> Option<tiny_skia::Path> {
    // The arrow's outline (22×24 box, y down) in absolute coordinates.
    let mut p = PathBuilder::new();
    p.move_to(3.2, 2.6);
    p.cubic_to(3.2, 1.6, 4.3, 1.1, 5.1, 1.7);
    p.line_to(18.7, 12.3);
    p.cubic_to(19.5, 12.9, 19.1, 14.2, 18.1, 14.3);
    p.line_to(12.5, 14.9);
    p.line_to(9.4, 20.7);
    p.cubic_to(8.9, 21.6, 7.6, 21.4, 7.4, 20.4);
    p.close();
    p.finish()
}

/// One frame: premultiplied RGBA, `size`×`size` pixels, tip at the centre. `press` scales
/// the arrow (1 = rest), `ring` is the click ring's progress (0..1), `alpha` the opacity.
pub fn render(scale: f32, press: f32, ring: Option<f32>, alpha: f32) -> Option<(Vec<u8>, u32)> {
    let size = (CANVAS_PT * scale).round().max(1.0) as u32;
    let mut pix = Pixmap::new(size, size)?;
    let c = size as f32 / 2.0;
    let path = arrow()?;
    let s = scale * press;
    let at = |dx: f32, dy: f32| Transform::from_translate(c - TIP.0 * s + dx, c - TIP.1 * s + dy).pre_scale(s, s);
    if let Some(p) = ring {
        let r = (4.0 + 36.0 * p) * scale;
        if let Some(circle) = PathBuilder::from_circle(c, c, r) {
            let mut paint = Paint::default();
            paint.set_color(Color::from_rgba8(CLAY.0, CLAY.1, CLAY.2, (204.0 * (1.0 - p) * alpha) as u8));
            paint.anti_alias = true;
            pix.stroke_path(&circle, &paint, &Stroke { width: 2.0 * scale, ..Default::default() }, Transform::identity(), None);
        }
    }
    // Soft shadow: a few faint offset copies.
    let mut shadow = Paint::default();
    shadow.anti_alias = true;
    shadow.set_color(Color::from_rgba8(0, 0, 0, (22.0 * alpha) as u8));
    for (dx, dy) in [(0.0, 1.0), (0.6, 1.4), (-0.6, 1.4), (0.0, 2.0)] {
        pix.fill_path(&path, &shadow, FillRule::Winding, at(dx * scale, dy * scale), None);
    }
    let mut fill = Paint::default();
    fill.anti_alias = true;
    fill.set_color(Color::from_rgba8(CLAY.0, CLAY.1, CLAY.2, (255.0 * alpha) as u8));
    pix.fill_path(&path, &fill, FillRule::Winding, at(0.0, 0.0), None);
    let mut edge = Paint::default();
    edge.anti_alias = true;
    edge.set_color(Color::from_rgba8(255, 255, 255, (255.0 * alpha) as u8));
    let stroke = Stroke { width: 1.6, line_join: tiny_skia::LineJoin::Round, ..Default::default() };
    pix.stroke_path(&path, &edge, &stroke, at(0.0, 0.0), None);
    Some((pix.take(), size))
}

/// A glide from the pointer's position to a target (screen pixels).
pub struct Glide {
    from: (f64, f64),
    ctrl: (f64, f64),
    to: (f64, f64),
    start: Instant,
    pub duration: Duration,
}

impl Glide {
    /// `scale`: pixels per point at the target (durations are defined in points).
    pub fn new(from: (f64, f64), to: (f64, f64), speed: f64, scale: f64) -> Self {
        let (dx, dy) = (to.0 - from.0, to.1 - from.1);
        let dist = (dx * dx + dy * dy).sqrt();
        // The midpoint pushed sideways by ±0.225 × distance: a natural, slightly curved path.
        let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.subsec_nanos()).unwrap_or(0);
        let r = (nanos % 1000) as f64 / 1000.0 * 2.0 - 1.0;
        let bend = 0.225 * r;
        let ctrl = (from.0 + dx / 2.0 - dy * bend, from.1 + dy / 2.0 + dx * bend);
        let ms = ((380.0 + 1.5 * dist / scale.max(0.1)) / speed.max(0.25)).min(1100.0);
        Self { from, ctrl, to, start: Instant::now(), duration: Duration::from_millis(if dist < 1.0 { 0 } else { ms as u64 }) }
    }

    /// Position now, and whether the glide is over.
    pub fn at(&self, now: Instant) -> ((f64, f64), bool) {
        if self.duration.is_zero() {
            return (self.to, true);
        }
        let t = (now.saturating_duration_since(self.start).as_secs_f64() / self.duration.as_secs_f64()).min(1.0);
        let e = if t < 0.5 { 4.0 * t * t * t } else { 1.0 - (-2.0 * t + 2.0).powi(3) / 2.0 };
        let u = 1.0 - e;
        let p = (
            u * u * self.from.0 + 2.0 * u * e * self.ctrl.0 + e * e * self.to.0,
            u * u * self.from.1 + 2.0 * u * e * self.ctrl.1 + e * e * self.to.1,
        );
        (p, t >= 1.0)
    }
}

/// Click feedback over time: (arrow press scale, ring progress) at `ms` after the click.
pub fn click_feedback(ms: u64) -> (f32, Option<f32>) {
    let press = if ms < 120 { 0.86 + 0.14 * ms as f32 / 120.0 } else { 1.0 };
    let ring = (ms < RING_MS).then(|| ms as f32 / RING_MS as f32);
    (press, ring)
}

/// Commands to a platform's pointer window thread.
pub enum Cmd {
    /// The glide itself travels alongside (it is computed where the start point is known).
    Glide { show: bool },
    Click,
    Hide,
}

/// The pointer window's animation loop, shared by Windows and Linux: follows the commands
/// (glide, click, hide), fades in on appearance, dims 2 s after the last movement, and redraws
/// only when something changed. `show` maps / unmaps the window, `draw` shows one frame (tip
/// position, press scale, ring progress, opacity), `pump` handles the window's messages.
pub fn animate(
    rx: std::sync::mpsc::Receiver<(Cmd, Option<Glide>)>,
    mut show: impl FnMut(bool),
    mut draw: impl FnMut((f64, f64), f32, Option<f32>, f32),
    mut pump: impl FnMut(),
) {
    use std::sync::mpsc::{RecvTimeoutError, TryRecvError};
    let mut glide: Option<Glide> = None;
    let mut pos = (0.0, 0.0);
    let (mut shown, mut want_shown) = (false, false);
    let mut clicked: Option<Instant> = None;
    let mut moved = Instant::now();
    let mut appear: Option<Instant> = None;
    let mut dirty = true;
    loop {
        // Poll while animating, otherwise sleep until the next command.
        let busy = glide.is_some() || clicked.is_some() || appear.is_some();
        let next = if busy {
            rx.try_recv().map_err(|e| matches!(e, TryRecvError::Disconnected))
        } else {
            rx.recv_timeout(Duration::from_millis(250)).map_err(|e| matches!(e, RecvTimeoutError::Disconnected))
        };
        match next {
            Ok((Cmd::Glide { show }, g)) => {
                if !shown && show {
                    appear = Some(Instant::now());
                }
                if let Some(g) = g {
                    if !shown {
                        // Not on screen: start where the glide ends.
                        pos = g.at(Instant::now() + g.duration).0;
                    }
                    glide = Some(g);
                }
                want_shown = show;
                moved = Instant::now();
                dirty = true;
            }
            Ok((Cmd::Click, _)) => {
                clicked = Some(Instant::now());
                moved = Instant::now();
            }
            Ok((Cmd::Hide, _)) => {
                want_shown = false;
                glide = None;
            }
            Err(true) => break,
            Err(false) => {}
        }
        pump();
        let now = Instant::now();
        if let Some(g) = &glide {
            let (p, done) = g.at(now);
            pos = p;
            dirty = true;
            if done {
                glide = None;
                moved = now;
            }
        }
        if want_shown != shown {
            show(want_shown);
            shown = want_shown;
            dirty = true;
        }
        if !shown {
            if glide.is_some() {
                std::thread::sleep(Duration::from_millis(8));
            }
            continue;
        }
        let (press, ring) = match clicked {
            Some(t) => {
                let ms = t.elapsed().as_millis() as u64;
                if ms >= RING_MS {
                    clicked = None;
                }
                dirty = true;
                click_feedback(ms)
            }
            None => (1.0, None),
        };
        let fade = appear.map(|t| (t.elapsed().as_secs_f32() / 0.2).min(1.0)).unwrap_or(1.0);
        if fade >= 1.0 {
            appear = None;
        }
        // 2 s after the last movement the arrow dims.
        let idle = glide.is_none() && clicked.is_none() && moved.elapsed() > Duration::from_secs(2);
        let alpha = fade * if idle { 0.4 } else { 1.0 };
        if !(dirty || appear.is_some() || (idle && moved.elapsed() < Duration::from_millis(2300))) {
            continue;
        }
        dirty = false;
        draw(pos, press, ring, alpha);
        std::thread::sleep(Duration::from_millis(8));
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn glide_ends_at_target_and_render_has_pixels() {
        let g = super::Glide::new((0.0, 0.0), (300.0, 200.0), 1.0, 1.0);
        assert!(g.duration.as_millis() > 380 && g.duration.as_millis() <= 1100);
        let (p, done) = g.at(std::time::Instant::now() + g.duration);
        assert!(done && (p.0 - 300.0).abs() < 1e-6 && (p.1 - 200.0).abs() < 1e-6);
        let (px, size) = super::render(1.0, 1.0, Some(0.5), 1.0).unwrap();
        assert_eq!(size, 96);
        assert!(px.chunks(4).any(|c| c[3] > 200), "arrow drawn");
    }
}
