//! The shared window as a PipeWire video stream (Wayland). The compositor sends a frame when
//! the window changes; the latest one is kept, so a screenshot is a copy, not a round trip.
//! Frames show the window even while other windows cover it.

use std::os::fd::OwnedFd;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use image::RgbaImage;
use pipewire as pw;
use pw::spa;

struct Raw {
    bytes: Vec<u8>,
    width: u32,
    height: u32,
    stride: usize,
    /// Byte order is B, G, R(, A).
    bgr: bool,
}

pub struct Frames {
    latest: Mutex<Option<Raw>>,
    arrived: Condvar,
    pub alive: AtomicBool,
}

/// A frame of the stream.
pub struct Frame {
    pub image: RgbaImage,
}

impl Frames {
    /// Connect to the portal's PipeWire remote and follow `node` on a thread of its own.
    pub fn start(fd: OwnedFd, node: u32) -> Arc<Self> {
        let me = Arc::new(Self { latest: Mutex::new(None), arrived: Condvar::new(), alive: AtomicBool::new(true) });
        let m = me.clone();
        std::thread::Builder::new()
            .name("screencast".into())
            .spawn(move || {
                if let Err(e) = Self::run(&m, fd, node) {
                    turbo_core::log::error(format!("window stream stopped: {e}"));
                }
                m.alive.store(false, Ordering::SeqCst);
                m.arrived.notify_all();
            })
            .ok();
        me
    }


    /// The latest frame (waiting up to `wait` for the first one).
    pub fn latest(&self, wait: Duration) -> Option<Frame> {
        let until = Instant::now() + wait;
        let mut g = self.latest.lock().unwrap();
        while g.is_none() && self.alive.load(Ordering::SeqCst) {
            let left = until.checked_duration_since(Instant::now())?;
            g = self.arrived.wait_timeout(g, left).ok()?.0;
        }
        g.as_ref().map(convert)
    }

    fn run(me: &Arc<Self>, fd: OwnedFd, node: u32) -> Result<(), String> {
        pw::init();
        let mainloop = pw::main_loop::MainLoopRc::new(None).map_err(|e| e.to_string())?;
        let context = pw::context::ContextRc::new(&mainloop, None).map_err(|e| e.to_string())?;
        let core = context.connect_fd_rc(fd, None).map_err(|e| e.to_string())?;
        let stream = pw::stream::StreamBox::new(
            &core,
            "computer-use-turbo",
            pw::properties::properties! {
                *pw::keys::MEDIA_TYPE => "Video",
                *pw::keys::MEDIA_CATEGORY => "Capture",
                *pw::keys::MEDIA_ROLE => "Screen",
            },
        )
        .map_err(|e| e.to_string())?;
        let ml = mainloop.clone();
        let sink = me.clone();
        let _listener = stream
            .add_local_listener_with_user_data(spa::param::video::VideoInfoRaw::default())
            .state_changed(move |_, _, _, new| {
                if matches!(new, pw::stream::StreamState::Error(_) | pw::stream::StreamState::Unconnected) {
                    ml.quit();
                }
            })
            .param_changed(|_, format, id, param| {
                if let Some(param) = param {
                    if id == spa::param::ParamType::Format.as_raw() {
                        let _ = format.parse(param);
                    }
                }
            })
            .process(move |s, format| {
                let Some(mut buffer) = s.dequeue_buffer() else { return };
                let datas = buffer.datas_mut();
                let Some(d) = datas.first_mut() else { return };
                let (width, height) = (format.size().width, format.size().height);
                let (offset, size, stride) = (d.chunk().offset() as usize, d.chunk().size() as usize, d.chunk().stride().max(0) as usize);
                let fmt = format.format();
                let Some(bytes) = d.data() else { return };
                if width == 0 || height == 0 || size == 0 || offset + size > bytes.len() {
                    return;
                }
                use spa::param::video::VideoFormat as F;
                let bgr = match fmt {
                    F::BGRA | F::BGRx => true,
                    F::RGBA | F::RGBx => false,
                    _ => return,
                };
                let raw = Raw {
                    bytes: bytes[offset..offset + size].to_vec(),
                    width,
                    height,
                    stride: if stride == 0 { width as usize * 4 } else { stride },
                    bgr,
                };
                *sink.latest.lock().unwrap() = Some(raw);
                sink.arrived.notify_all();
            })
            .register()
            .map_err(|e| e.to_string())?;
        let format = spa::pod::object!(
            spa::utils::SpaTypes::ObjectParamFormat,
            spa::param::ParamType::EnumFormat,
            spa::pod::property!(spa::param::format::FormatProperties::MediaType, Id, spa::param::format::MediaType::Video),
            spa::pod::property!(spa::param::format::FormatProperties::MediaSubtype, Id, spa::param::format::MediaSubtype::Raw),
            spa::pod::property!(
                spa::param::format::FormatProperties::VideoFormat,
                Choice,
                Enum,
                Id,
                spa::param::video::VideoFormat::BGRA,
                spa::param::video::VideoFormat::BGRA,
                spa::param::video::VideoFormat::BGRx,
                spa::param::video::VideoFormat::RGBA,
                spa::param::video::VideoFormat::RGBx
            ),
            spa::pod::property!(
                spa::param::format::FormatProperties::VideoSize,
                Choice,
                Range,
                Rectangle,
                spa::utils::Rectangle { width: 1920, height: 1080 },
                spa::utils::Rectangle { width: 1, height: 1 },
                spa::utils::Rectangle { width: 16384, height: 16384 }
            ),
            spa::pod::property!(
                spa::param::format::FormatProperties::VideoFramerate,
                Choice,
                Range,
                Fraction,
                spa::utils::Fraction { num: 30, denom: 1 },
                spa::utils::Fraction { num: 0, denom: 1 },
                spa::utils::Fraction { num: 1000, denom: 1 }
            ),
        );
        let bytes: Vec<u8> = spa::pod::serialize::PodSerializer::serialize(std::io::Cursor::new(Vec::new()), &spa::pod::Value::Object(format))
            .map_err(|e| format!("{e:?}"))?
            .0
            .into_inner();
        let mut params = [spa::pod::Pod::from_bytes(&bytes).ok_or("bad format pod")?];
        stream
            .connect(spa::utils::Direction::Input, Some(node), pw::stream::StreamFlags::AUTOCONNECT | pw::stream::StreamFlags::MAP_BUFFERS, &mut params)
            .map_err(|e| e.to_string())?;
        mainloop.run();
        Ok(())
    }
}

/// RGBA copy (opaque).
fn convert(raw: &Raw) -> Frame {
    let (w, h) = (raw.width, raw.height);
    let mut image = RgbaImage::new(w, h);
    for y in 0..h {
        let row = y as usize * raw.stride;
        for x in 0..w {
            let i = row + x as usize * 4;
            if i + 3 >= raw.bytes.len() {
                break;
            }
            let p = &raw.bytes[i..i + 4];
            let (r, g, b) = if raw.bgr { (p[2], p[1], p[0]) } else { (p[0], p[1], p[2]) };
            image.put_pixel(x, y, image::Rgba([r, g, b, 255]));
        }
    }
    Frame { image }
}
