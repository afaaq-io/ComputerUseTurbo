//! The agent pointer on Windows: a small layered window (per-pixel
//! alpha through `UpdateLayeredWindow`, drawn in software — no GPU), always on top, never
//! activated, transparent to the mouse and excluded from screen capture. Its own thread
//! animates it; the user's real cursor is never touched.

use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::Mutex;
use std::time::Duration;

use windows::core::w;
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, POINT, SIZE, WPARAM};
use windows::Win32::Graphics::Gdi::{
    CreateCompatibleDC, CreateDIBSection, DeleteDC, DeleteObject, GetDC, MonitorFromPoint, ReleaseDC, SelectObject, AC_SRC_ALPHA, AC_SRC_OVER, BITMAPINFO,
    BITMAPINFOHEADER, BI_RGB, BLENDFUNCTION, DIB_RGB_COLORS, HBITMAP, HDC, MONITOR_DEFAULTTONEAREST,
};
use windows::Win32::UI::HiDpi::{GetDpiForMonitor, MDT_EFFECTIVE_DPI};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DispatchMessageW, PeekMessageW, RegisterClassW, SetWindowDisplayAffinity, ShowWindow, TranslateMessage, UpdateLayeredWindow, MSG,
    PM_REMOVE, SW_HIDE, SW_SHOWNOACTIVATE, ULW_ALPHA, WDA_EXCLUDEFROMCAPTURE, WNDCLASSW, WS_EX_LAYERED, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_EX_TOPMOST,
    WS_EX_TRANSPARENT, WS_POPUP,
};

use crate::pointer_art::{self, Cmd, Glide};

pub struct Pointer {
    tx: Mutex<Option<Sender<(Cmd, Option<Glide>)>>>,
    /// Where the arrow's tip is (or ends up), screen pixels; None until it first appears.
    pos: Mutex<Option<(f64, f64)>>,
}

impl Pointer {
    pub fn new() -> Self {
        Self { tx: Mutex::new(None), pos: Mutex::new(None) }
    }

    fn send(&self, cmd: Cmd, glide: Option<Glide>) {
        let mut g = self.tx.lock().unwrap();
        if g.is_none() {
            let (tx, rx) = channel();
            if std::thread::Builder::new().name("agent-pointer".into()).spawn(move || run(rx)).is_ok() {
                *g = Some(tx);
            }
        }
        if let Some(tx) = g.as_ref() {
            if tx.send((cmd, glide)).is_err() {
                *g = None;
            }
        }
    }

    /// Glide to (x, y); returns the glide's duration.
    pub fn glide(&self, x: f64, y: f64, show: bool, speed: f64) -> Duration {
        let scale = dpi_scale(x, y);
        let mut pos = self.pos.lock().unwrap();
        // First appearance: fade in at the target (the glide starts and ends there).
        let from = pos.unwrap_or((x, y));
        let glide = Glide::new(from, (x, y), speed, scale);
        let d = glide.duration.max(if pos.is_none() { Duration::from_millis(200) } else { Duration::ZERO });
        *pos = Some((x, y));
        drop(pos);
        self.send(Cmd::Glide { show }, Some(glide));
        d
    }

    pub fn click(&self) {
        self.send(Cmd::Click, None);
    }

    pub fn hide(&self) {
        *self.pos.lock().unwrap() = None;
        if self.tx.lock().unwrap().is_some() {
            self.send(Cmd::Hide, None);
        }
    }
}

fn dpi_scale(x: f64, y: f64) -> f64 {
    unsafe {
        let mon = MonitorFromPoint(POINT { x: x as i32, y: y as i32 }, MONITOR_DEFAULTTONEAREST);
        let (mut dx, mut dy) = (96u32, 96u32);
        if GetDpiForMonitor(mon, MDT_EFFECTIVE_DPI, &mut dx, &mut dy).is_ok() {
            dx as f64 / 96.0
        } else {
            1.0
        }
    }
}

unsafe extern "system" fn wndproc(h: HWND, m: u32, w: WPARAM, l: LPARAM) -> LRESULT {
    DefWindowProcW(h, m, w, l)
}

/// A 32-bit top-down DIB the frames are drawn into.
struct Surface {
    dc: HDC,
    bitmap: HBITMAP,
    bits: *mut u8,
    size: u32,
}

impl Surface {
    unsafe fn new(screen: HDC, size: u32) -> Option<Self> {
        let dc = CreateCompatibleDC(screen);
        let info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: size as i32,
                biHeight: -(size as i32),
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        let mut bits: *mut core::ffi::c_void = std::ptr::null_mut();
        let bitmap = CreateDIBSection(dc, &info, DIB_RGB_COLORS, &mut bits, None, 0).ok()?;
        SelectObject(dc, bitmap);
        Some(Self { dc, bitmap, bits: bits as *mut u8, size })
    }

    /// Premultiplied RGBA → the DIB's premultiplied BGRA.
    unsafe fn draw(&self, rgba: &[u8]) {
        let out = std::slice::from_raw_parts_mut(self.bits, (self.size * self.size * 4) as usize);
        for (o, i) in out.chunks_exact_mut(4).zip(rgba.chunks_exact(4)) {
            o.copy_from_slice(&[i[2], i[1], i[0], i[3]]);
        }
    }
}

impl Drop for Surface {
    fn drop(&mut self) {
        unsafe {
            let _ = DeleteObject(self.bitmap);
            let _ = DeleteDC(self.dc);
        }
    }
}

fn run(rx: Receiver<(Cmd, Option<Glide>)>) {
    unsafe {
        let class = w!("ComputerUseTurboAgentPointer");
        let wc = WNDCLASSW { lpfnWndProc: Some(wndproc), lpszClassName: class, ..Default::default() };
        RegisterClassW(&wc);
        let Ok(hwnd) = CreateWindowExW(
            WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
            class,
            w!(""),
            WS_POPUP,
            0,
            0,
            1,
            1,
            None,
            None,
            None,
            None,
        ) else {
            turbo_core::log::error("agent pointer: could not create its window");
            return;
        };
        let _ = SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);
        let screen = GetDC(None);
        let mut surface: Option<Surface> = None;
        pointer_art::animate(
            rx,
            |on| {
                let _ = ShowWindow(hwnd, if on { SW_SHOWNOACTIVATE } else { SW_HIDE });
            },
            |pos, press, ring, alpha| {
                let scale = dpi_scale(pos.0, pos.1) as f32;
                let Some((rgba, size)) = pointer_art::render(scale, press, ring, alpha) else { return };
                if surface.as_ref().map_or(true, |s| s.size != size) {
                    surface = Surface::new(screen, size);
                }
                let Some(s) = &surface else { return };
                s.draw(&rgba);
                let half = size as i32 / 2;
                let at = POINT { x: pos.0.round() as i32 - half, y: pos.1.round() as i32 - half };
                let blend = BLENDFUNCTION { BlendOp: AC_SRC_OVER as u8, BlendFlags: 0, SourceConstantAlpha: 255, AlphaFormat: AC_SRC_ALPHA as u8 };
                let _ = UpdateLayeredWindow(
                    hwnd,
                    screen,
                    Some(&at),
                    Some(&SIZE { cx: size as i32, cy: size as i32 }),
                    s.dc,
                    Some(&POINT { x: 0, y: 0 }),
                    COLORREF(0),
                    Some(&blend),
                    ULW_ALPHA,
                );
            },
            || {
                let mut msg = MSG::default();
                while PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE).as_bool() {
                    let _ = TranslateMessage(&msg);
                    DispatchMessageW(&msg);
                }
            },
        );
        ReleaseDC(None, screen);
    }
}
