//! Colours of the overlay, approval card and preview from `shared/design-tokens.json`,
//! following the system's light / dark appearance.

use eframe::egui::Color32;
use serde_json::Value;

const TOKENS: &str = include_str!("../../../../../shared/design-tokens.json");

#[derive(Clone)]
pub struct Palette {
    pub surface: Color32,
    pub border: Color32,
    pub text: Color32,
    pub text_secondary: Color32,
    pub text_tertiary: Color32,
    pub warning: Color32,
    pub dot: Color32,
    pub dot_stopped: Color32,
    pub stop_fill: Color32,
    pub stop_border: Color32,
    pub stop_text: Color32,
    pub primary_fill: Color32,
    pub primary_text: Color32,
    pub button_fill: Color32,
    pub button_border: Color32,
    pub button_text: Color32,
    pub text_button: Color32,
    pub preview_bg: Color32,
}

fn color(v: &Value, key: &str, fallback: Color32) -> Color32 {
    let Some(c) = v.get(key) else { return fallback };
    let f = |k: &str| c.get(k).and_then(Value::as_f64).unwrap_or(0.0);
    Color32::from_rgba_unmultiplied((f("r") * 255.0) as u8, (f("g") * 255.0) as u8, (f("b") * 255.0) as u8, (f("a") * 255.0) as u8)
}

impl Palette {
    pub fn current() -> Self {
        Self::for_mode(system_dark())
    }

    pub fn for_mode(dark: bool) -> Self {
        let root: Value = serde_json::from_str(TOKENS).unwrap_or(Value::Null);
        let p = &root[if dark { "dark" } else { "light" }];
        let opaque = |c: Color32| Color32::from_rgb(c.r(), c.g(), c.b());
        let base = if dark { Color32::from_rgb(40, 40, 44) } else { Color32::from_rgb(245, 245, 247) };
        Self {
            // No blur on these platforms: the opaque surface keeps text contrast.
            surface: opaque(color(p, "surfaceOpaque", base)),
            border: color(p, "border", Color32::from_black_alpha(30)),
            text: color(p, "textPrimary", Color32::BLACK),
            text_secondary: color(p, "textSecondary", Color32::DARK_GRAY),
            text_tertiary: color(p, "textTertiary", Color32::GRAY),
            warning: color(p, "warning", Color32::from_rgb(138, 83, 0)),
            dot: color(p, "dotActive", Color32::from_rgb(217, 119, 87)),
            dot_stopped: color(p, "dotStopped", Color32::GRAY),
            stop_fill: color(p, "stopFill", Color32::from_rgba_unmultiplied(255, 59, 48, 30)),
            stop_border: color(p, "stopBorder", Color32::from_rgb(200, 30, 20)),
            stop_text: color(p, "stopText", Color32::from_rgb(163, 21, 13)),
            primary_fill: color(p, "primaryFill", Color32::from_rgb(184, 87, 58)),
            primary_text: color(p, "primaryText", Color32::WHITE),
            button_fill: color(p, "buttonFill", Color32::WHITE),
            button_border: color(p, "buttonBorder", Color32::GRAY),
            button_text: color(p, "buttonText", Color32::BLACK),
            text_button: color(p, "textButtonText", Color32::DARK_GRAY),
            preview_bg: opaque(color(p, "previewBackground", base)),
        }
    }
}

/// Whether the system uses a dark appearance.
#[cfg(windows)]
pub fn system_dark() -> bool {
    use windows::core::w;
    use windows::Win32::System::Registry::{RegGetValueW, HKEY_CURRENT_USER, RRF_RT_REG_DWORD};
    let mut value: u32 = 1;
    let mut size = std::mem::size_of::<u32>() as u32;
    let r = unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            w!("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"),
            w!("AppsUseLightTheme"),
            RRF_RT_REG_DWORD,
            None,
            Some(&mut value as *mut u32 as *mut _),
            Some(&mut size),
        )
    };
    r.is_ok() && value == 0
}

/// XDG portal / GNOME `color-scheme`, else a GTK theme ending in `-dark`.
#[cfg(not(windows))]
pub fn system_dark() -> bool {
    let run = |args: &[&str]| {
        std::process::Command::new("gsettings").args(args).output().ok().map(|o| String::from_utf8_lossy(&o.stdout).to_lowercase())
    };
    if let Some(s) = run(&["get", "org.gnome.desktop.interface", "color-scheme"]) {
        if s.contains("dark") {
            return true;
        }
        if s.contains("light") {
            return false;
        }
    }
    if let Ok(theme) = std::env::var("GTK_THEME") {
        return theme.to_lowercase().contains("dark");
    }
    run(&["get", "org.gnome.desktop.interface", "gtk-theme"]).is_some_and(|s| s.contains("-dark"))
}
