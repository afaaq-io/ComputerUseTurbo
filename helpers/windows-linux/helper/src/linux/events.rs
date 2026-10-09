//! AT-SPI events of the apps being worked on: a thread of its own
//! listens on the accessibility bus, keeps what happened in watched apps in the core's
//! `EventLog`, and wakes `waitFor` checks.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};

use turbo_core::events::{describe, EventKind, EventLog, UiEvent};
use zbus::blocking::{Connection, ConnectionBuilder, MessageIterator};
use zbus::zvariant::OwnedValue;

use super::atspi::{Atspi, El};

const EVENT_INTERFACES: [&str; 4] =
    ["org.a11y.atspi.Event.Object", "org.a11y.atspi.Event.Window", "org.a11y.atspi.Event.Focus", "org.a11y.atspi.Event.Document"];
const REGISTERED: [&str; 4] = ["object:", "window:", "focus:", "document:"];

pub struct Events {
    pub log: Arc<EventLog>,
    watched: Arc<Mutex<HashSet<u32>>>,
    started: Mutex<bool>,
}

impl Events {
    pub fn new() -> Self {
        Self { log: Arc::new(EventLog::default()), watched: Arc::new(Mutex::new(HashSet::new())), started: Mutex::new(false) }
    }

    /// Watch `pid`; the listener thread starts with the first app.
    pub fn watch(&self, pid: u32) {
        self.watched.lock().unwrap().insert(pid);
        let mut started = self.started.lock().unwrap();
        if *started {
            return;
        }
        *started = true;
        let (log, watched) = (self.log.clone(), self.watched.clone());
        let _ = std::thread::Builder::new().name("turbo-atspi-events".into()).spawn(move || {
            if let Err(e) = listen(log, watched) {
                turbo_core::log::error(format!("AT-SPI events unavailable: {e}"));
            }
        });
    }
}

fn listen(log: Arc<EventLog>, watched: Arc<Mutex<HashSet<u32>>>) -> zbus::Result<()> {
    let session = Connection::session()?;
    let conn = ConnectionBuilder::address(Atspi::address(&session)?.as_str())?.build()?;
    let dbus = zbus::blocking::fdo::DBusProxy::new(&conn)?;
    for iface in EVENT_INTERFACES {
        let rule = zbus::MatchRule::builder().msg_type(zbus::message::Type::Signal).interface(iface)?.build();
        dbus.add_match_rule(rule)?;
    }
    // Apps only send what someone registered for.
    for ev in REGISTERED {
        let reg = Some("org.a11y.atspi.Registry");
        let path = "/org/a11y/atspi/registry";
        let iface = Some("org.a11y.atspi.Registry");
        if conn.call_method(reg, path, iface, "RegisterEvent", &(ev, Vec::<String>::new(), "")).is_err() {
            let _ = conn.call_method(reg, path, iface, "RegisterEvent", &(ev,));
        }
    }
    let reader = Atspi::connect()?;
    let mut pids: HashMap<String, Option<u32>> = HashMap::new();
    turbo_core::log::info("AT-SPI events: listening");
    for msg in MessageIterator::from(&conn) {
        let Ok(msg) = msg else { continue };
        let header = msg.header();
        let (Some(iface), Some(member), Some(sender), Some(path)) = (header.interface(), header.member(), header.sender(), header.path()) else { continue };
        let iface = iface.as_str().to_string();
        if !iface.starts_with("org.a11y.atspi.Event.") {
            continue;
        }
        let sender = sender.as_str().to_string();
        let pid = *pids.entry(sender.clone()).or_insert_with(|| reader.pid_of(&sender));
        let Some(pid) = pid.filter(|p| watched.lock().unwrap().contains(p)) else { continue };
        let (kind, detail1, any) = match msg.body().deserialize::<(String, i32, i32, OwnedValue, HashMap<String, OwnedValue>)>() {
            Ok((k, d1, _, v, _)) => (k, d1, Some(v)),
            Err(_) => match msg.body().deserialize::<(String, i32, i32, OwnedValue)>() {
                Ok((k, d1, _, v)) => (k, d1, Some(v)),
                Err(_) => (String::new(), 0, None),
            },
        };
        let el = El { bus: sender, path: path.as_str().to_string() };
        let event = describe_event(&reader, &iface, member.as_str(), &kind, detail1, any, &el);
        log.push(pid, event);
    }
    Ok(())
}

fn what(a: &Atspi, el: &El) -> (String, Option<String>, bool) {
    let role = a.role_name(el).unwrap_or_default();
    let secure = role == "password text";
    let shown = match role.as_str() {
        "entry" | "spin button" | "password text" => "text field",
        "text" => "text",
        "push button" => "button",
        "frame" | "window" => "window",
        "dialog" | "alert" | "file chooser" => "dialog",
        r => r,
    }
    .to_string();
    (shown, a.name(el), secure)
}

fn describe_event(a: &Atspi, iface: &str, member: &str, kind: &str, detail1: i32, any: Option<OwnedValue>, el: &El) -> Option<UiEvent> {
    let key = el.key();
    match (iface.rsplit('.').next().unwrap_or(""), member) {
        ("Window", "Create") => {
            if a.extents(el).is_some_and(|(_, _, w, h)| turbo_core::events::incidental_window(w as f64, h as f64)) {
                return None;
            }
            let (role, name, _) = what(a, el);
            let k = if role == "dialog" { EventKind::DialogOpened } else { EventKind::WindowOpened };
            Some(UiEvent::new(k).what(name.map(|n| format!("\"{n}\"")).unwrap_or_default()).key(key))
        }
        ("Window", "Destroy") => Some(UiEvent::new(EventKind::WindowClosed).key(key)),
        ("Focus", "Focus") => {
            let (role, name, _) = what(a, el);
            Some(UiEvent::new(EventKind::FocusMoved).what(describe(&role, name.as_deref())).key(key))
        }
        ("Object", "StateChanged") if kind == "focused" && detail1 == 1 => {
            let (role, name, _) = what(a, el);
            Some(UiEvent::new(EventKind::FocusMoved).what(describe(&role, name.as_deref())).key(key))
        }
        ("Object", "TextChanged") => {
            let (role, name, secure) = what(a, el);
            if secure {
                return None;
            }
            let text = a.text(el).map(|t| if t.chars().count() > 120 { t.chars().take(119).collect::<String>() + "…" } else { t });
            Some(UiEvent::new(EventKind::ValueChanged).what(describe(&role, name.as_deref())).detail(text).key(key))
        }
        ("Object", "PropertyChange") if kind == "accessible-value" => {
            let (role, name, secure) = what(a, el);
            if secure {
                return None;
            }
            let v = a.value(el).map(|v| if v.fract() == 0.0 { format!("{}", v as i64) } else { format!("{v}") });
            Some(UiEvent::new(EventKind::ValueChanged).what(describe(&role, name.as_deref())).detail(v).key(key))
        }
        ("Object", "PropertyChange") if kind == "accessible-name" => {
            let (role, name, _) = what(a, el);
            matches!(role.as_str(), "window" | "dialog" | "label" | "text" | "status bar")
                .then(|| UiEvent::new(EventKind::TitleChanged).what(role).detail(name).key(key))
        }
        ("Object", "SelectionChanged") => {
            let (role, name, _) = what(a, el);
            Some(UiEvent::new(EventKind::SelectionChanged).what(describe(&role, name.as_deref())).key(key))
        }
        ("Object", "Announcement") => {
            let text = any.and_then(|v| String::try_from(v).ok()).filter(|t| !t.is_empty())?;
            Some(UiEvent::new(EventKind::Announcement).detail(Some(text)))
        }
        ("Object", "StateChanged") if kind == "showing" && detail1 == 1 && a.role_name(el).as_deref() == Some("menu") => {
            Some(UiEvent::new(EventKind::MenuOpened).what(a.name(el).map(|n| format!("\"{n}\"")).unwrap_or_default()).key(key))
        }
        ("Document", "LoadComplete") => Some(UiEvent::new(EventKind::PageLoaded).what(a.name(el).map(|n| format!("\"{n}\"")).unwrap_or_default())),
        // Everything else (children added / removed, layout) only wakes waits.
        _ => None,
    }
}
