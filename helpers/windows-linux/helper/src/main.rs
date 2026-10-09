//! Computer Use Turbo helper for Windows and Linux.
//!
//!   computer-use-turbo-helper              run the helper (one instance per user)
//!   computer-use-turbo-helper --version
//!   computer-use-turbo-helper --ui <mode>  one of its own windows (used internally)
//!   computer-use-turbo-helper --share-screen  Linux / Wayland: ask once to share the screen

#![cfg_attr(not(any(windows, target_os = "linux")), allow(dead_code))]
// A GUI program on Windows: starting the helper or its windows never opens a console.
#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]

mod ui;

#[cfg(any(windows, target_os = "linux"))]
mod pointer_art;

#[cfg(target_os = "linux")]
mod linux;
#[cfg(windows)]
mod windows;

fn main() {
    #[cfg(target_os = "linux")]
    linux::restore_session_env();
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("--version") => {
            // A GUI-subsystem program has no console of its own: print into the caller's.
            #[cfg(windows)]
            unsafe {
                let _ = ::windows::Win32::System::Console::AttachConsole(::windows::Win32::System::Console::ATTACH_PARENT_PROCESS);
            }
            println!("computer-use-turbo-helper {} ({})", turbo_core::protocol::HELPER_VERSION, turbo_core::protocol::API_VERSION);
        }
        #[cfg(target_os = "linux")]
        Some("--share-screen") => {
            let paths = turbo_core::paths::Paths::current();
            let _ = paths.ensure();
            std::process::exit(linux::share_screen_once(paths.screen_shares()));
        }
        Some("--ui") => {
            let code = ui::run(args.get(2).map(String::as_str).unwrap_or(""), args.get(3).map(String::as_str));
            std::process::exit(code);
        }
        _ => std::process::exit(run()),
    }
}

#[cfg(any(windows, target_os = "linux"))]
fn run() -> i32 {
    use std::sync::{Arc, OnceLock, Weak};
    use turbo_core::{log, paths::Paths, service::Service};

    #[cfg(target_os = "linux")]
    type Native = linux::Native;
    #[cfg(windows)]
    type Native = windows::Native;

    let paths = Paths::current();
    if let Err(e) = paths.ensure() {
        eprintln!("cannot create {}: {e}", paths.support.display());
        return 1;
    }
    // One helper per user.
    let lock = match std::fs::OpenOptions::new().create(true).truncate(false).write(true).open(paths.lock()) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("cannot open the lock file: {e}");
            return 1;
        }
    };
    if lock.try_lock().is_err() {
        return 0;
    }
    log::init(&paths.log);
    log::info(format!("computer-use-turbo-helper {} starting (pid {})", turbo_core::protocol::HELPER_VERSION, std::process::id()));
    turbo_core::image_util::sweep(&paths.shots, 600);

    let service_cell: Arc<OnceLock<Weak<Service<Native>>>> = Arc::new(OnceLock::new());
    let stop = {
        let cell = service_cell.clone();
        Arc::new(move || {
            if let Some(s) = cell.get().and_then(Weak::upgrade) {
                s.user_stop();
            }
        }) as Arc<dyn Fn() + Send + Sync>
    };
    // Esc stops the agent only while it is working (the overlay is up).
    let esc = {
        let cell = service_cell.clone();
        let stop = stop.clone();
        Arc::new(move || {
            if cell.get().and_then(Weak::upgrade).is_some_and(|s| s.active_recently()) {
                stop();
            }
        }) as Arc<dyn Fn() + Send + Sync>
    };
    let platform = Arc::new(Native::new(esc));
    let ui = Arc::new(ui::ChildUi::new(stop));
    let service = Service::new(platform, ui, paths.clone());
    let _ = service_cell.set(Arc::downgrade(&service));
    {
        use turbo_core::platform::Platform;
        let p = service.platform.permissions();
        log::info(format!("ready: accessibility={} screen={}", p.accessibility, p.screen));
    }

    #[cfg(target_os = "linux")]
    let r = linux::listen(&paths.endpoint, move |stream, n| turbo_core::service::serve(&service, stream, &format!("conn {n}")));
    #[cfg(windows)]
    let r = windows::listen(&paths.endpoint, move |stream, n| turbo_core::service::serve(&service, stream, &format!("conn {n}")));
    match r {
        Ok(()) => 0,
        Err(e) => {
            log::error(format!("listener failed: {e}"));
            1
        }
    }
}

#[cfg(not(any(windows, target_os = "linux")))]
fn run() -> i32 {
    eprintln!("This helper is for Windows and Linux. On macOS use helpers/macos (Computer Use Turbo.app).");
    1
}
