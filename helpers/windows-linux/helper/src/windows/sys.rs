//! Win32 plumbing: top-level windows and their processes, window frames, capture
//! (PrintWindow with full content, so covered windows work), the foreground window, and
//! low-level hooks that record the user's own input (injected input is ignored).

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use image::RgbaImage;
use turbo_core::platform::Rect;
use windows::core::PWSTR;
use windows::Win32::Foundation::{BOOL, CloseHandle, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows::Win32::Graphics::Dwm::{DwmGetWindowAttribute, DWMWA_CLOAKED, DWMWA_EXTENDED_FRAME_BOUNDS};
use windows::Win32::Graphics::Gdi::{
    CreateCompatibleBitmap, CreateCompatibleDC, DeleteDC, DeleteObject, GetDC, GetDIBits, ReleaseDC, SelectObject, BITMAPINFO,
    BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS,
};
use windows::Win32::Storage::FileSystem::{GetFileVersionInfoSizeW, GetFileVersionInfoW, VerQueryValueW};
use windows::Win32::System::StationsAndDesktops::{CloseDesktop, OpenInputDesktop, DESKTOP_ACCESS_FLAGS, DESKTOP_CONTROL_FLAGS};
use windows::Win32::System::Threading::{OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION};
use windows::Win32::UI::Input::KeyboardAndMouse::{SendInput, INPUT, INPUT_0, VK_ESCAPE};
use windows::Win32::UI::WindowsAndMessaging::{
    BringWindowToTop, CallNextHookEx, EnumWindows, GetAncestor, GetForegroundWindow, GetMessageW, GetWindow, GetWindowLongW,
    GetWindowRect, GetWindowTextLengthW, GetWindowTextW, GetWindowThreadProcessId, IsIconic, IsWindow, IsWindowVisible,
    SetForegroundWindow, SetWindowsHookExW, ShowWindow, WindowFromPoint, GA_ROOT, GWL_EXSTYLE, GW_OWNER, KBDLLHOOKSTRUCT, MSG,
    MSLLHOOKSTRUCT, SW_RESTORE, WH_KEYBOARD_LL, WH_MOUSE_LL, WM_KEYDOWN, WM_LBUTTONDOWN, WM_MBUTTONDOWN, WM_RBUTTONDOWN,
    WM_SYSKEYDOWN, WS_EX_TOOLWINDOW,
};

pub fn hwnd(h: u64) -> HWND {
    HWND(h as usize as *mut _)
}

pub fn handle_of(h: HWND) -> u64 {
    h.0 as usize as u64
}

pub fn pid_of(h: HWND) -> u32 {
    let mut pid = 0u32;
    unsafe { GetWindowThreadProcessId(h, Some(&mut pid)) };
    pid
}

pub fn title(h: HWND) -> String {
    unsafe {
        let n = GetWindowTextLengthW(h);
        if n <= 0 {
            return String::new();
        }
        let mut buf = vec![0u16; n as usize + 1];
        let got = GetWindowTextW(h, &mut buf);
        String::from_utf16_lossy(&buf[..got.max(0) as usize])
    }
}

fn cloaked(h: HWND) -> bool {
    let mut v: u32 = 0;
    unsafe { DwmGetWindowAttribute(h, DWMWA_CLOAKED, &mut v as *mut u32 as *mut _, 4).is_ok() && v != 0 }
}

/// Visible, uncloaked, unowned top-level windows with a title (what the taskbar shows).
pub fn app_windows() -> Vec<HWND> {
    unsafe extern "system" fn collect(h: HWND, l: LPARAM) -> BOOL {
        let out = &mut *(l.0 as *mut Vec<HWND>);
        let owned = GetWindow(h, GW_OWNER).map(|o| !o.0.is_null()).unwrap_or(false);
        let tool = (GetWindowLongW(h, GWL_EXSTYLE) as u32 & WS_EX_TOOLWINDOW.0) != 0;
        if IsWindowVisible(h).as_bool() && !owned && !tool && GetWindowTextLengthW(h) > 0 && !cloaked(h) {
            out.push(h);
        }
        BOOL(1)
    }
    let mut out: Vec<HWND> = vec![];
    unsafe {
        let _ = EnumWindows(Some(collect), LPARAM(&mut out as *mut _ as isize));
    }
    out
}

/// Also visible owned windows (dialogs) of a process.
pub fn windows_of(pid: u32) -> Vec<HWND> {
    unsafe extern "system" fn collect(h: HWND, l: LPARAM) -> BOOL {
        let (pid, out) = &mut *(l.0 as *mut (u32, Vec<HWND>));
        if IsWindowVisible(h).as_bool() && pid_of(h) == *pid && !cloaked(h) {
            let mut r = RECT::default();
            if GetWindowRect(h, &mut r).is_ok() && r.right - r.left > 40 && r.bottom - r.top > 30 {
                out.push(h);
            }
        }
        BOOL(1)
    }
    let mut data: (u32, Vec<HWND>) = (pid, vec![]);
    unsafe {
        let _ = EnumWindows(Some(collect), LPARAM(&mut data as *mut _ as isize));
    }
    data.1
}

pub fn is_window(h: HWND) -> bool {
    unsafe { IsWindow(h).as_bool() }
}

/// The visible frame (without the invisible resize borders).
pub fn frame(h: HWND) -> Option<Rect> {
    let mut r = RECT::default();
    unsafe {
        if DwmGetWindowAttribute(h, DWMWA_EXTENDED_FRAME_BOUNDS, &mut r as *mut RECT as *mut _, std::mem::size_of::<RECT>() as u32).is_err() {
            GetWindowRect(h, &mut r).ok()?;
        }
    }
    let rect = Rect { x: r.left as f64, y: r.top as f64, w: (r.right - r.left) as f64, h: (r.bottom - r.top) as f64 };
    (rect.w > 0.0 && rect.h > 0.0).then_some(rect)
}

pub fn exe_path(pid: u32) -> Option<String> {
    unsafe {
        let h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        let mut buf = vec![0u16; 1024];
        let mut len = buf.len() as u32;
        let r = QueryFullProcessImageNameW(h, PROCESS_NAME_WIN32, PWSTR(buf.as_mut_ptr()), &mut len);
        let _ = CloseHandle(h);
        r.ok()?;
        Some(String::from_utf16_lossy(&buf[..len as usize]))
    }
}

pub fn exe_id(pid: u32) -> Option<String> {
    let p = exe_path(pid)?;
    std::path::Path::new(&p).file_name().map(|n| n.to_string_lossy().to_lowercase())
}

/// The executable a packaged app runs, by its app user model id
/// ("Microsoft.WindowsNotepad_8wekyb3d8bbwe!App" → "notepad.exe"), from the package's
/// manifest. App ids are executable names everywhere (approvals, policy lists), also for apps
/// started through the Start menu.
pub fn packaged_exe(aumid: &str) -> Option<String> {
    use windows::core::PCWSTR;
    use windows::Win32::Storage::Packaging::Appx::{GetPackagePathByFullName, GetPackagesByPackageFamily};
    let (family, app_id) = aumid.split_once('!')?;
    let family_w: Vec<u16> = family.encode_utf16().chain(Some(0)).collect();
    let (mut count, mut buf_len) = (0u32, 0u32);
    unsafe {
        let _ = GetPackagesByPackageFamily(PCWSTR(family_w.as_ptr()), &mut count, None, &mut buf_len, PWSTR::null());
        if count == 0 || buf_len == 0 {
            return None;
        }
        let mut names = vec![PWSTR::null(); count as usize];
        let mut buf = vec![0u16; buf_len as usize];
        if GetPackagesByPackageFamily(PCWSTR(family_w.as_ptr()), &mut count, Some(names.as_mut_ptr()), &mut buf_len, PWSTR(buf.as_mut_ptr())).is_err() {
            return None;
        }
        let full = names.first()?;
        let mut path_len = 0u32;
        let _ = GetPackagePathByFullName(PCWSTR(full.0), &mut path_len, PWSTR::null());
        let mut path = vec![0u16; path_len.max(1) as usize];
        if GetPackagePathByFullName(PCWSTR(full.0), &mut path_len, PWSTR(path.as_mut_ptr())).is_err() {
            return None;
        }
        let dir = String::from_utf16_lossy(&path[..path_len.saturating_sub(1) as usize]);
        let manifest = std::fs::read_to_string(std::path::Path::new(&dir).join("AppxManifest.xml")).ok()?;
        manifest_executable(&manifest, app_id)
    }
}

/// `Executable` of the `<Application Id="app_id">` element of an AppxManifest.
fn manifest_executable(manifest: &str, app_id: &str) -> Option<String> {
    // Attributes are matched with whitespace before the name ("Id" is not "AppId").
    let attr = |tag: &str, name: &str| -> Option<String> {
        let key = format!("{name}=\"");
        let start = tag.match_indices(&key).find(|(i, _)| tag[..*i].ends_with(char::is_whitespace))?.0 + key.len();
        Some(tag[start..].split('"').next()?.to_string())
    };
    for part in manifest.split("<Application").skip(1).filter(|p| p.starts_with(char::is_whitespace)) {
        let tag = part.split('>').next()?;
        if attr(tag, "Id").is_some_and(|id| id.eq_ignore_ascii_case(app_id)) {
            let exe = attr(tag, "Executable")?;
            return std::path::Path::new(&exe.replace('\\', "/")).file_name().map(|f| f.to_string_lossy().to_lowercase());
        }
    }
    None
}

/// FileDescription from the executable's version resource ("Notepad", "Google Chrome").
pub fn product_name(path: &str) -> Option<String> {
    let wide: Vec<u16> = path.encode_utf16().chain(Some(0)).collect();
    unsafe {
        let size = GetFileVersionInfoSizeW(windows::core::PCWSTR(wide.as_ptr()), None);
        if size == 0 {
            return None;
        }
        let mut data = vec![0u8; size as usize];
        GetFileVersionInfoW(windows::core::PCWSTR(wide.as_ptr()), 0, size, data.as_mut_ptr() as *mut _).ok()?;
        let mut ptr: *mut core::ffi::c_void = std::ptr::null_mut();
        let mut len = 0u32;
        let q: Vec<u16> = "\\VarFileInfo\\Translation".encode_utf16().chain(Some(0)).collect();
        if !VerQueryValueW(data.as_ptr() as *const _, windows::core::PCWSTR(q.as_ptr()), &mut ptr, &mut len).as_bool() || len < 4 {
            return None;
        }
        let lang = *(ptr as *const u16);
        let cp = *(ptr as *const u16).add(1);
        let key: Vec<u16> = format!("\\StringFileInfo\\{lang:04x}{cp:04x}\\FileDescription").encode_utf16().chain(Some(0)).collect();
        if !VerQueryValueW(data.as_ptr() as *const _, windows::core::PCWSTR(key.as_ptr()), &mut ptr, &mut len).as_bool() || len == 0 {
            return None;
        }
        let s = std::slice::from_raw_parts(ptr as *const u16, len as usize);
        let name = String::from_utf16_lossy(s).trim_end_matches('\0').trim().to_string();
        (!name.is_empty()).then_some(name)
    }
}

pub fn foreground_pid() -> Option<u32> {
    let h = unsafe { GetForegroundWindow() };
    (!h.0.is_null()).then(|| pid_of(h))
}

/// Bring a window to the foreground. Windows only lets the foreground app or the app that
/// sent the last input change the foreground: a synthetic mouse move of zero makes the helper
/// that app without touching anything (an Alt tap would put modern apps into key-tip mode,
/// where the next letters pick commands instead of typing). If that is not enough, the
/// helper joins the foreground window's input queue for the switch.
pub fn activate(h: HWND) -> bool {
    use windows::Win32::System::Threading::{AttachThreadInput, GetCurrentThreadId};
    use windows::Win32::UI::Input::KeyboardAndMouse::{INPUT_MOUSE, MOUSEEVENTF_MOVE, MOUSEINPUT};
    use windows::Win32::UI::WindowsAndMessaging::GetWindowThreadProcessId;
    unsafe {
        if IsIconic(h).as_bool() {
            let _ = ShowWindow(h, SW_RESTORE);
        }
        let nudge = INPUT {
            r#type: INPUT_MOUSE,
            Anonymous: INPUT_0 { mi: MOUSEINPUT { dx: 0, dy: 0, mouseData: 0, dwFlags: MOUSEEVENTF_MOVE, time: 0, dwExtraInfo: crate::windows::input::TAG } },
        };
        SendInput(&[nudge], std::mem::size_of::<INPUT>() as i32);
        let _ = BringWindowToTop(h);
        let mut ok = SetForegroundWindow(h).as_bool();
        if !ok {
            let fg_thread = GetWindowThreadProcessId(GetForegroundWindow(), None);
            let me = GetCurrentThreadId();
            if fg_thread != 0 && fg_thread != me && AttachThreadInput(me, fg_thread, true).as_bool() {
                let _ = BringWindowToTop(h);
                ok = SetForegroundWindow(h).as_bool();
                let _ = AttachThreadInput(me, fg_thread, false);
            }
        }
        std::thread::sleep(Duration::from_millis(60));
        ok || GetForegroundWindow() == h
    }
}

pub fn screen_locked() -> bool {
    unsafe {
        match OpenInputDesktop(DESKTOP_CONTROL_FLAGS(0), false, DESKTOP_ACCESS_FLAGS(0x0100)) {
            Ok(d) => {
                let _ = CloseDesktop(d);
                false
            }
            Err(_) => true,
        }
    }
}

/// Capture a window's content (works while it is covered) cropped to its visible frame.
pub fn capture(h: HWND) -> Option<RgbaImage> {
    let mut wr = RECT::default();
    unsafe { GetWindowRect(h, &mut wr).ok()? };
    let (w, ht) = (wr.right - wr.left, wr.bottom - wr.top);
    if w <= 0 || ht <= 0 {
        return None;
    }
    let vis = frame(h)?;
    unsafe {
        let screen = GetDC(HWND::default());
        let mem = CreateCompatibleDC(screen);
        let bmp = CreateCompatibleBitmap(screen, w, ht);
        let old = SelectObject(mem, bmp);
        // PW_RENDERFULLCONTENT (2): also DirectComposition / GPU-rendered content.
        let ok = windows::Win32::Storage::Xps::PrintWindow(h, mem, windows::Win32::Storage::Xps::PRINT_WINDOW_FLAGS(2)).as_bool();
        let mut info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: w,
                biHeight: -ht,
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        let mut buf = vec![0u8; (w * ht * 4) as usize];
        let lines = GetDIBits(mem, bmp, 0, ht as u32, Some(buf.as_mut_ptr() as *mut _), &mut info, DIB_RGB_COLORS);
        SelectObject(mem, old);
        let _ = DeleteObject(bmp);
        let _ = DeleteDC(mem);
        ReleaseDC(HWND::default(), screen);
        if !ok || lines == 0 {
            return None;
        }
        let (ox, oy) = ((vis.x as i32 - wr.left).max(0), (vis.y as i32 - wr.top).max(0));
        let (cw, ch) = ((vis.w as i32).min(w - ox), (vis.h as i32).min(ht - oy));
        let mut out = RgbaImage::new(cw as u32, ch as u32);
        for y in 0..ch {
            for x in 0..cw {
                let o = (((y + oy) * w + (x + ox)) * 4) as usize;
                out.put_pixel(x as u32, y as u32, image::Rgba([buf[o + 2], buf[o + 1], buf[o], 255]));
            }
        }
        Some(out)
    }
}

// ---------------------------------------------------------------- hooks

static LAST_REAL_MS: AtomicU64 = AtomicU64::new(0);
static START: OnceLock<Instant> = OnceLock::new();
static PER_PID: OnceLock<Mutex<HashMap<u32, Instant>>> = OnceLock::new();
static ON_ESC: OnceLock<Arc<dyn Fn() + Send + Sync>> = OnceLock::new();

fn now_ms() -> u64 {
    START.get_or_init(Instant::now).elapsed().as_millis() as u64
}

pub fn idle_seconds() -> f64 {
    let last = LAST_REAL_MS.load(Ordering::Relaxed);
    if last == 0 {
        return 3600.0;
    }
    (now_ms().saturating_sub(last)) as f64 / 1000.0
}

pub fn last_input_on(pid: u32) -> Option<Instant> {
    PER_PID.get()?.lock().ok()?.get(&pid).copied()
}

fn record(pid: u32) {
    if let Some(m) = PER_PID.get() {
        if let Ok(mut g) = m.lock() {
            g.insert(pid, Instant::now());
        }
    }
}

unsafe extern "system" fn mouse_hook(code: i32, w: WPARAM, l: LPARAM) -> LRESULT {
    if code >= 0 {
        let info = &*(l.0 as *const MSLLHOOKSTRUCT);
        if info.flags & 1 == 0 {
            LAST_REAL_MS.store(now_ms().max(1), Ordering::Relaxed);
            let msg = w.0 as u32;
            if msg == WM_LBUTTONDOWN || msg == WM_RBUTTONDOWN || msg == WM_MBUTTONDOWN {
                let root = GetAncestor(WindowFromPoint(POINT { x: info.pt.x, y: info.pt.y }), GA_ROOT);
                record(pid_of(root));
            }
        }
    }
    CallNextHookEx(None, code, w, l)
}

unsafe extern "system" fn keyboard_hook(code: i32, w: WPARAM, l: LPARAM) -> LRESULT {
    if code >= 0 {
        let info = &*(l.0 as *const KBDLLHOOKSTRUCT);
        if info.flags.0 & 0x10 == 0 {
            LAST_REAL_MS.store(now_ms().max(1), Ordering::Relaxed);
            let msg = w.0 as u32;
            if msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN {
                if let Some(pid) = foreground_pid() {
                    record(pid);
                }
                if info.vkCode == VK_ESCAPE.0 as u32 {
                    if let Some(f) = ON_ESC.get() {
                        let f = f.clone();
                        std::thread::spawn(move || f());
                    }
                }
            }
        }
    }
    CallNextHookEx(None, code, w, l)
}

/// Install the low-level hooks on their own thread (they need a message loop).
pub fn start_hooks(on_esc: Arc<dyn Fn() + Send + Sync>) {
    START.get_or_init(Instant::now);
    PER_PID.get_or_init(|| Mutex::new(HashMap::new()));
    let _ = ON_ESC.set(on_esc);
    std::thread::Builder::new()
        .name("input-hooks".into())
        .spawn(|| unsafe {
            let m = SetWindowsHookExW(WH_MOUSE_LL, Some(mouse_hook), None, 0);
            let k = SetWindowsHookExW(WH_KEYBOARD_LL, Some(keyboard_hook), None, 0);
            if m.is_err() || k.is_err() {
                turbo_core::log::error("could not install the input hooks (take-back and Esc will not work)");
            }
            let mut msg = MSG::default();
            while GetMessageW(&mut msg, None, 0, 0).as_bool() {}
        })
        .ok();
}

/// Restore a minimized window without activating it; true when it was minimized.
pub fn restore_quietly(h: HWND) -> bool {
    use windows::Win32::UI::WindowsAndMessaging::SW_SHOWNOACTIVATE;
    unsafe {
        if !IsIconic(h).as_bool() {
            return false;
        }
        let _ = ShowWindow(h, SW_SHOWNOACTIVATE);
    }
    // The app redraws (a suspended Store app resumes) before it can be read.
    let until = Instant::now() + Duration::from_millis(1500);
    while Instant::now() < until && unsafe { IsIconic(h).as_bool() } {
        std::thread::sleep(Duration::from_millis(50));
    }
    std::thread::sleep(Duration::from_millis(400));
    true
}

/// The window's class name ("ApplicationFrameWindow", "Notepad", …).
pub fn class(h: HWND) -> String {
    let mut buf = [0u16; 256];
    let n = unsafe { windows::Win32::UI::WindowsAndMessaging::GetClassNameW(h, &mut buf) };
    String::from_utf16_lossy(&buf[..n.max(0) as usize])
}

pub fn owner(h: HWND) -> Option<HWND> {
    unsafe { GetWindow(h, GW_OWNER).ok().filter(|o| !o.0.is_null()) }
}

/// The CoreWindow of a packaged app hosted by an ApplicationFrameHost window: inside the
/// frame while the app is shown; while it is minimized or suspended Windows takes it out, and
/// it is the top-level CoreWindow with the frame's title.
pub fn windows_of_child_core(frame: HWND) -> Option<HWND> {
    use windows::core::w;
    use windows::Win32::UI::WindowsAndMessaging::FindWindowExW;
    unsafe {
        if let Some(h) = FindWindowExW(frame, None, w!("Windows.UI.Core.CoreWindow"), None).ok().filter(|h| !h.0.is_null()) {
            return Some(h);
        }
        let title = title(frame);
        if title.is_empty() {
            return None;
        }
        let mut after = HWND::default();
        loop {
            let h = FindWindowExW(None, after, w!("Windows.UI.Core.CoreWindow"), None).ok().filter(|h| !h.0.is_null())?;
            if self::title(h) == title {
                return Some(h);
            }
            after = h;
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn manifest_executable() {
        let m = r#"<Applications><Application Id="App" Executable="Notepad\Notepad.exe" EntryPoint="Windows.FullTrustApplication"><uap:VisualElements/></Application>
            <Application
              AppId="x" Id="Other" Executable="Other.exe"></Application></Applications>"#;
        assert_eq!(super::manifest_executable(m, "App").as_deref(), Some("notepad.exe"));
        assert_eq!(super::manifest_executable(m, "other").as_deref(), Some("other.exe"));
        assert_eq!(super::manifest_executable(m, "Missing"), None);
    }
}
