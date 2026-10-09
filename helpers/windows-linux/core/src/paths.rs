//! Per-platform locations; must match `server/src/paths.mjs`.

use std::path::PathBuf;

pub const PRODUCT_DIR: &str = "ComputerUseTurbo";
pub const PRODUCT_SLUG: &str = "computer-use-turbo";

/// The user's runtime directory when XDG_RUNTIME_DIR is not set (agent apps may start MCP
/// servers with a minimal environment): `/run/user/<uid>`, if it exists.
#[cfg(unix)]
pub fn runtime_dir() -> Option<String> {
    use std::os::unix::fs::MetadataExt;
    let uid = std::fs::metadata("/proc/self").ok()?.uid();
    let dir = format!("/run/user/{uid}");
    std::path::Path::new(&dir).is_dir().then_some(dir)
}

#[cfg(not(unix))]
pub fn runtime_dir() -> Option<String> {
    None
}

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.is_empty())
}

fn home() -> PathBuf {
    env("HOME").or_else(|| env("USERPROFILE")).map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."))
}

#[derive(Clone, Debug)]
pub struct Paths {
    pub support: PathBuf,
    /// Unix socket path, or the Windows named pipe name.
    pub endpoint: String,
    pub shots: PathBuf,
    pub log: PathBuf,
}

impl Paths {
    pub fn current() -> Self {
        if cfg!(windows) {
            let local = env("LOCALAPPDATA").map(PathBuf::from).unwrap_or_else(|| home().join("AppData").join("Local"));
            let support = local.join(PRODUCT_DIR);
            let user = env("USERNAME").unwrap_or_else(|| "user".into());
            Self {
                endpoint: env("CUT_SOCKET_PATH").unwrap_or_else(|| format!(r"\\.\pipe\{PRODUCT_SLUG}-{user}")),
                shots: env("CUT_SCREENSHOT_DIR").map(PathBuf::from).unwrap_or_else(|| local.join(PRODUCT_DIR).join("shots")),
                log: support.join("logs").join("helper.log"),
                support,
            }
        } else {
            let state = env("XDG_STATE_HOME").map(PathBuf::from).unwrap_or_else(|| home().join(".local").join("state"));
            let support = state.join(PRODUCT_SLUG);
            let endpoint = env("CUT_SOCKET_PATH").unwrap_or_else(|| match env("XDG_RUNTIME_DIR").or_else(runtime_dir) {
                Some(rt) => PathBuf::from(rt).join(format!("{PRODUCT_SLUG}.sock")).to_string_lossy().into_owned(),
                None => support.join("turbo.sock").to_string_lossy().into_owned(),
            });
            let cache = env("XDG_CACHE_HOME").map(PathBuf::from).unwrap_or_else(|| home().join(".cache"));
            Self {
                endpoint,
                shots: env("CUT_SCREENSHOT_DIR").map(PathBuf::from).unwrap_or_else(|| cache.join(PRODUCT_SLUG).join("shots")),
                log: support.join("logs").join("helper.log"),
                support,
            }
        }
    }

    pub fn settings(&self) -> PathBuf {
        self.support.join("settings.json")
    }
    pub fn allow_protected(&self) -> PathBuf {
        self.support.join("allow-protected.txt")
    }
    pub fn profiles(&self) -> PathBuf {
        self.support.join("app-profiles.json")
    }
    /// Wayland: the screen-sharing approvals (portal restore tokens) per app.
    pub fn screen_shares(&self) -> PathBuf {
        self.support.join("screen-shares.json")
    }
    pub fn lock(&self) -> PathBuf {
        self.support.join("helper.lock")
    }

    /// Create the support / shots / log directories (owner-only on Unix).
    pub fn ensure(&self) -> std::io::Result<()> {
        for d in [&self.support, &self.shots, self.log.parent().unwrap_or(&self.support)] {
            std::fs::create_dir_all(d)?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = std::fs::set_permissions(d, std::fs::Permissions::from_mode(0o700));
            }
        }
        Ok(())
    }
}
