//! XDG desktop portal (D-Bus) for Wayland: one RemoteDesktop session sharing the screen
//! (every monitor) with remote input. The user approves it once — choose the screen, allow
//! remote interaction — and the portal hands back a restore token, so later sessions start
//! without asking again, for every app.

use std::collections::HashMap;
use std::os::fd::OwnedFd;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{mpsc, Arc};
use std::time::Duration;

use zbus::blocking::{Connection, MessageIterator};
use zbus::zvariant::{ObjectPath, OwnedValue, Value};

const DEST: &str = "org.freedesktop.portal.Desktop";
const PATH: &str = "/org/freedesktop/portal/desktop";
const REMOTE: &str = "org.freedesktop.portal.RemoteDesktop";
const CAST: &str = "org.freedesktop.portal.ScreenCast";
const PROPS: &str = "org.freedesktop.DBus.Properties";

/// Device types: keyboard | pointer. Source type: monitor. Cursor: hidden.
const DEVICES: u32 = 1 | 2;
const SOURCE_MONITOR: u32 = 1;
const CURSOR_HIDDEN: u32 = 1;
/// Keep the permission until the user revokes it.
const PERSIST_UNTIL_REVOKED: u32 = 2;

/// One shared monitor: its PipeWire node and where it sits in the desktop (logical pixels).
pub struct Stream {
    pub node: u32,
    pub position: (i32, i32),
    pub size: (i32, i32),
}

pub struct Started {
    pub session: String,
    pub streams: Vec<Stream>,
    pub restore_token: Option<String>,
    pub keyboard_and_pointer: bool,
}

pub enum StartError {
    /// The user cancelled the prompt.
    Declined,
    /// No answer within the time allowed.
    NoAnswer,
    Failed(String),
}

pub struct Portal {
    conn: Connection,
    n: AtomicU32,
}

type Body<'a> = HashMap<&'a str, Value<'a>>;

impl Portal {
    pub fn connect() -> Option<Self> {
        Some(Self { conn: Connection::session().ok()?, n: AtomicU32::new(0) })
    }

    fn property(&self, iface: &str, name: &str) -> Option<OwnedValue> {
        self.conn.call_method(Some(DEST), PATH, Some(PROPS), "Get", &(iface, name)).ok()?.body().deserialize::<OwnedValue>().ok()
    }

    fn version(&self, iface: &str) -> u32 {
        self.property(iface, "version").and_then(|v| u32::try_from(v).ok()).unwrap_or(0)
    }

    /// Screen capture with remote input and restore tokens: RemoteDesktop 2 (input through
    /// EIS), ScreenCast 4 (restore tokens) offering monitor sources.
    pub fn supported(&self) -> bool {
        let monitors = self.property(CAST, "AvailableSourceTypes").and_then(|v| u32::try_from(v).ok()).unwrap_or(0) & SOURCE_MONITOR != 0;
        self.version(REMOTE) >= 2 && self.version(CAST) >= 4 && monitors
    }

    fn token(&self) -> String {
        format!("turbo{}_{}", std::process::id(), self.n.fetch_add(1, Ordering::Relaxed))
    }

    /// Call a method that answers through a Request object and wait for its Response.
    fn request<B>(&self, iface: &str, method: &str, body: &B, token: &str, wait: Duration) -> Result<(u32, HashMap<String, OwnedValue>), StartError>
    where
        B: zbus::export::serde::ser::Serialize + zbus::zvariant::DynamicType,
    {
        let sender = self.conn.unique_name().map(|n| n.trim_start_matches(':').replace('.', "_")).unwrap_or_default();
        let path = format!("{PATH}/request/{sender}/{token}");
        let rule = zbus::MatchRule::builder()
            .msg_type(zbus::message::Type::Signal)
            .interface("org.freedesktop.portal.Request")
            .and_then(|b| b.member("Response"))
            .and_then(|b| b.path(path.clone()))
            .map_err(|e| StartError::Failed(e.to_string()))?
            .build();
        let mut answers = MessageIterator::for_match_rule(rule, &self.conn, Some(4)).map_err(|e| StartError::Failed(e.to_string()))?;
        self.conn.call_method(Some(DEST), PATH, Some(iface), method, body).map_err(|e| StartError::Failed(format!("{method}: {e}")))?;
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let answer = answers.next().and_then(|m| m.ok()).and_then(|m| m.body().deserialize::<(u32, HashMap<String, OwnedValue>)>().ok());
            let _ = tx.send(answer);
        });
        match rx.recv_timeout(wait) {
            Ok(Some((0, results))) => Ok((0, results)),
            Ok(Some((1, _))) => Err(StartError::Declined),
            Ok(Some((code, _))) => Err(StartError::Failed(format!("{method} ended with code {code}"))),
            Ok(None) => Err(StartError::Failed(format!("{method}: no answer"))),
            Err(_) => {
                let _ = self.conn.call_method(Some(DEST), path.as_str(), Some("org.freedesktop.portal.Request"), "Close", &());
                Err(StartError::NoAnswer)
            }
        }
    }

    /// Open a session: the user is asked (unless `restore` still holds) which window to share
    /// and whether remote interaction is allowed.
    pub fn start(&self, restore: Option<&str>, ask_for: Duration) -> Result<Started, StartError> {
        let quick = Duration::from_secs(10);
        let (t, st) = (self.token(), self.token());
        let opts: Body = [("handle_token", Value::from(t.as_str())), ("session_handle_token", Value::from(st.as_str()))].into_iter().collect();
        let (_, mut r) = self.request(REMOTE, "CreateSession", &(opts,), &t, quick)?;
        let session = r.remove("session_handle").and_then(|v| String::try_from(v).ok()).ok_or_else(|| StartError::Failed("no session handle".into()))?;
        let result = self.configure_and_start(&session, restore, ask_for);
        if result.is_err() {
            self.close(&session);
        }
        result
    }

    fn configure_and_start(&self, session: &str, restore: Option<&str>, ask_for: Duration) -> Result<Started, StartError> {
        let quick = Duration::from_secs(10);
        let sp = ObjectPath::try_from(session).map_err(|e| StartError::Failed(e.to_string()))?;
        let t = self.token();
        let mut opts: Body = [("handle_token", Value::from(t.as_str())), ("types", Value::from(DEVICES)), ("persist_mode", Value::from(PERSIST_UNTIL_REVOKED))].into_iter().collect();
        if let Some(tok) = restore.filter(|t| !t.is_empty()) {
            opts.insert("restore_token", Value::from(tok));
        }
        self.request(REMOTE, "SelectDevices", &(&sp, opts), &t, quick)?;
        let t = self.token();
        let opts: Body = [
            ("handle_token", Value::from(t.as_str())),
            ("types", Value::from(SOURCE_MONITOR)),
            ("multiple", Value::from(true)),
            ("cursor_mode", Value::from(CURSOR_HIDDEN)),
        ]
        .into_iter()
        .collect();
        self.request(CAST, "SelectSources", &(&sp, opts), &t, quick)?;
        let t = self.token();
        let opts: Body = [("handle_token", Value::from(t.as_str()))].into_iter().collect();
        let (_, mut r) = self.request(REMOTE, "Start", &(&sp, "", opts), &t, ask_for)?;
        let devices = r.remove("devices").and_then(|v| u32::try_from(v).ok()).unwrap_or(0);
        let restore_token = r.remove("restore_token").and_then(|v| String::try_from(v).ok());
        let streams: Vec<(u32, HashMap<String, OwnedValue>)> = r.remove("streams").and_then(|v| v.try_into().ok()).unwrap_or_default();
        let pair = |props: &HashMap<String, OwnedValue>, key: &str| -> Option<(i32, i32)> {
            props.get(key).and_then(|v| v.try_clone().ok()).and_then(|v| <(i32, i32)>::try_from(v).ok())
        };
        let streams: Vec<Stream> = streams
            .into_iter()
            .map(|(node, props)| Stream { node, position: pair(&props, "position").unwrap_or((0, 0)), size: pair(&props, "size").unwrap_or((0, 0)) })
            .collect();
        if streams.is_empty() {
            return Err(StartError::Failed("no screen was shared".into()));
        }
        Ok(Started { session: session.to_string(), streams, restore_token, keyboard_and_pointer: devices & DEVICES == DEVICES })
    }

    fn fd(&self, iface: &str, method: &str, session: &str) -> Option<OwnedFd> {
        let sp = ObjectPath::try_from(session).ok()?;
        let empty: Body = HashMap::new();
        let fd: zbus::zvariant::OwnedFd = self.conn.call_method(Some(DEST), PATH, Some(iface), method, &(&sp, empty)).ok()?.body().deserialize().ok()?;
        Some(fd.into())
    }

    /// The PipeWire connection that carries the window stream.
    pub fn pipewire(&self, session: &str) -> Option<OwnedFd> {
        self.fd(CAST, "OpenPipeWireRemote", session)
    }

    /// The EIS socket for input (libei protocol).
    pub fn eis(&self, session: &str) -> Option<OwnedFd> {
        self.fd(REMOTE, "ConnectToEIS", session)
    }

    pub fn close(&self, session: &str) {
        let _ = self.conn.call_method(Some(DEST), session, Some("org.freedesktop.portal.Session"), "Close", &());
    }

    /// Set `closed` when the session ends from the other side (the user stops sharing).
    pub fn watch_closed(&self, session: &str, closed: Arc<AtomicBool>) {
        let Ok(rule) = zbus::MatchRule::builder()
            .msg_type(zbus::message::Type::Signal)
            .interface("org.freedesktop.portal.Session")
            .and_then(|b| b.member("Closed"))
            .and_then(|b| b.path(session.to_string()))
            .map(|b| b.build())
        else {
            return;
        };
        let Ok(mut it) = MessageIterator::for_match_rule(rule, &self.conn, Some(2)) else { return };
        std::thread::spawn(move || {
            if it.next().is_some() {
                closed.store(true, Ordering::SeqCst);
            }
        });
    }
}
