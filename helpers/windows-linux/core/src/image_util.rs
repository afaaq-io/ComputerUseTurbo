//! Screenshot pixel space: downscale so the longest side is ≤ 1568 px and the
//! area ≤ 1.15 MP, JPEG files, the 32×32 change thumbnail and blank-image detection.

use std::path::{Path, PathBuf};

use image::{imageops::FilterType, DynamicImage, RgbaImage};

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Geometry {
    pub width: u32,
    pub height: u32,
    pub scale: f64,
}

pub fn fit(w: f64, h: f64) -> Geometry {
    if w <= 0.0 || h <= 0.0 {
        return Geometry { width: 0, height: 0, scale: 1.0 };
    }
    let scale = 1f64.min(1568.0 / w.max(h)).min((1_150_000.0 / (w * h)).sqrt());
    let width = ((w * scale).floor() as u32).max(1);
    let height = ((h * scale).floor() as u32).max(1);
    Geometry { width, height, scale: width as f64 / w }
}

/// Screenshot pixel → screen coordinate.
pub fn to_screen(x: f64, y: f64, origin: (f64, f64), g: &Geometry) -> (f64, f64) {
    (origin.0 + x / g.scale, origin.1 + y / g.scale)
}

pub fn contains(x: f64, y: f64, g: &Geometry) -> bool {
    x >= -0.5 && y >= -0.5 && x <= g.width as f64 + 0.5 && y <= g.height as f64 + 0.5
}

pub struct Shot {
    pub path: PathBuf,
    pub width: u32,
    pub height: u32,
    pub scale: f64,
    pub thumbnail: Vec<u8>,
    pub possibly_blank: bool,
}

pub const THUMB: u32 = 32;

/// Resize to the geometry, write `<dir>/<name>.jpg`, return the shot.
pub fn save(image: &RgbaImage, g: &Geometry, dir: &Path, name: &str) -> std::io::Result<Shot> {
    std::fs::create_dir_all(dir)?;
    let img = DynamicImage::ImageRgba8(image.clone());
    let resized = if img.width() == g.width && img.height() == g.height {
        img
    } else {
        img.resize_exact(g.width.max(1), g.height.max(1), FilterType::Triangle)
    };
    let rgb = resized.to_rgb8();
    let path = dir.join(format!("{name}.jpg"));
    let mut file = std::fs::File::create(&path)?;
    let mut enc = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut file, 82);
    enc.encode_image(&rgb).map_err(std::io::Error::other)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    }
    let gray = DynamicImage::ImageRgb8(rgb).resize_exact(THUMB, THUMB, FilterType::Triangle).to_luma8();
    Ok(Shot {
        path,
        width: g.width,
        height: g.height,
        scale: g.scale,
        thumbnail: gray.into_raw(),
        possibly_blank: is_blank(image),
    })
}

/// ≥ 99 % of a 32×32 sample grid within 6 levels of the most common colour.
pub fn is_blank(image: &RgbaImage) -> bool {
    let (w, h) = image.dimensions();
    if w == 0 || h == 0 {
        return true;
    }
    let mut samples = vec![];
    for gy in 0..32 {
        for gx in 0..32 {
            let p = image.get_pixel(gx * (w - 1) / 31, gy * (h - 1) / 31).0;
            samples.push([p[0], p[1], p[2]]);
        }
    }
    let mut counts: std::collections::HashMap<[u8; 3], usize> = Default::default();
    for s in &samples {
        *counts.entry([s[0] / 8, s[1] / 8, s[2] / 8]).or_default() += 1;
    }
    let mode = counts.into_iter().max_by_key(|(_, c)| *c).map(|(k, _)| [k[0] * 8 + 4, k[1] * 8 + 4, k[2] * 8 + 4]).unwrap();
    let close = samples.iter().filter(|s| (0..3).all(|i| (s[i] as i32 - mode[i] as i32).abs() <= 6 + 4)).count();
    close * 100 >= samples.len() * 99
}

/// Share of thumbnail cells whose brightness moved by more than 8 levels.
pub fn change_fraction(previous: &[u8], current: &[u8]) -> Option<f64> {
    if previous.len() != current.len() || current.is_empty() {
        return None;
    }
    let changed = previous.iter().zip(current).filter(|(a, b)| (**a as i32 - **b as i32).abs() > 8).count();
    Some(changed as f64 / current.len() as f64)
}

/// Delete screenshots older than `max_age` seconds.
pub fn sweep(dir: &Path, max_age: u64) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for e in entries.flatten() {
        let old = e.metadata().ok().and_then(|m| m.modified().ok()).and_then(|t| t.elapsed().ok()).map(|d| d.as_secs() > max_age);
        if old == Some(true) {
            let _ = std::fs::remove_file(e.path());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fitting() {
        let g = fit(2560.0, 1320.0);
        assert_eq!((g.width, g.height), (1493, 770));
        assert!((g.scale - 0.5832).abs() < 0.001);
        assert_eq!(fit(800.0, 600.0).scale, 1.0);
    }
}
