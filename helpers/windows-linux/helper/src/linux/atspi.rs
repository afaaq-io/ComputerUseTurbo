//! AT-SPI 2 over D-Bus (the Linux accessibility API), called directly with zbus: the
//! accessibility bus, the registry's applications, and the Accessible / Component / Action /
//! Text / EditableText / Value interfaces.



use zbus::blocking::{Connection, ConnectionBuilder};
use zbus::zvariant::{OwnedObjectPath, OwnedValue, Value};

const ACCESSIBLE: &str = "org.a11y.atspi.Accessible";
const COMPONENT: &str = "org.a11y.atspi.Component";
const ACTION: &str = "org.a11y.atspi.Action";
const TEXT: &str = "org.a11y.atspi.Text";
const EDITABLE: &str = "org.a11y.atspi.EditableText";
const VALUE: &str = "org.a11y.atspi.Value";
const PROPS: &str = "org.freedesktop.DBus.Properties";

/// A remote accessible: bus name + object path.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct El {
    pub bus: String,
    pub path: String,
}

impl El {
    pub fn key(&self) -> String {
        format!("{}{}", self.bus, self.path)
    }
}

// AtspiStateType bit numbers.
pub mod state {
    pub const ACTIVE: u32 = 1;
    pub const CHECKED: u32 = 4;
    pub const DEFUNCT: u32 = 6;
    pub const EDITABLE: u32 = 7;
    pub const ENABLED: u32 = 8;
    pub const EXPANDED: u32 = 10;
    pub const FOCUSABLE: u32 = 11;
    pub const FOCUSED: u32 = 12;
    pub const MODAL: u32 = 16;
    pub const MULTI_LINE: u32 = 17;
    pub const SELECTED: u32 = 23;
    pub const SENSITIVE: u32 = 24;
    pub const SHOWING: u32 = 25;
    pub const VISIBLE: u32 = 30;
    pub const READ_ONLY: u32 = 43;
}

/// AtspiCoordType.
pub mod coord {
    pub const SCREEN: u32 = 0;
    pub const WINDOW: u32 = 1;
}

pub fn has(states: u64, bit: u32) -> bool {
    states & (1u64 << bit) != 0
}

pub struct Atspi {
    conn: Connection,
    session: Connection,
}

impl Atspi {
    pub fn connect() -> zbus::Result<Self> {
        let session = Connection::session()?;
        let conn = ConnectionBuilder::address(Self::address(&session)?.as_str())?.build()?;
        Ok(Self { conn, session })
    }

    /// The accessibility bus address (it is a bus of its own, next to the session bus).
    pub fn address(session: &Connection) -> zbus::Result<String> {
        session.call_method(Some("org.a11y.Bus"), "/org/a11y/bus", Some("org.a11y.Bus"), "GetAddress", &())?.body().deserialize()
    }

    /// (name, key binding) per action. A toolkit key binding reads
    /// "<mnemonic>;<mnemonic path>;<accelerator>", e.g. "s;<Alt>f:s;<Primary>s".
    pub fn actions_with_keys(&self, el: &El) -> Vec<(String, String)> {
        self.call::<_, Vec<(String, String, String)>>(el, ACTION, "GetActions", &())
            .unwrap_or_default()
            .into_iter()
            .map(|(n, _, k)| (n, k))
            .collect()
    }

    /// Whether assistive technologies are switched on for the session (`org.a11y.Status`).
    pub fn enabled(&self) -> bool {
        self.session
            .call_method(Some("org.a11y.Bus"), "/org/a11y/bus", Some(PROPS), "Get", &("org.a11y.Status", "IsEnabled"))
            .ok()
            .and_then(|m| m.body().deserialize::<OwnedValue>().ok())
            .and_then(|v| bool::try_from(v).ok())
            .unwrap_or(true)
    }

    /// Switch accessibility on for the session (what screen readers do).
    pub fn enable(&self) {
        let _ = self.session.call_method(
            Some("org.a11y.Bus"),
            "/org/a11y/bus",
            Some(PROPS),
            "Set",
            &("org.a11y.Status", "IsEnabled", Value::from(true)),
        );
    }

    fn call<B, R>(&self, el: &El, iface: &str, method: &str, body: &B) -> Option<R>
    where
        B: zbus::export::serde::ser::Serialize + zbus::zvariant::DynamicType,
        R: for<'d> zbus::zvariant::DynamicDeserialize<'d>,
    {
        let msg = self.conn.call_method(Some(el.bus.as_str()), el.path.as_str(), Some(iface), method, body).ok()?;
        msg.body().deserialize::<R>().ok()
    }

    fn prop(&self, el: &El, iface: &str, name: &str) -> Option<OwnedValue> {
        self.call::<_, OwnedValue>(el, PROPS, "Get", &(iface, name))
    }

    pub fn applications(&self) -> Vec<El> {
        self.children(&El { bus: "org.a11y.atspi.Registry".into(), path: "/org/a11y/atspi/accessible/root".into() })
    }

    pub fn children(&self, el: &El) -> Vec<El> {
        self.call::<_, Vec<(String, OwnedObjectPath)>>(el, ACCESSIBLE, "GetChildren", &())
            .unwrap_or_default()
            .into_iter()
            .filter(|(b, p)| !b.is_empty() && p.as_str() != "/org/a11y/atspi/null")
            .map(|(bus, path)| El { bus, path: path.as_str().to_string() })
            .collect()
    }

    pub fn role_name(&self, el: &El) -> Option<String> {
        self.call(el, ACCESSIBLE, "GetRoleName", &())
    }

    pub fn states(&self, el: &El) -> u64 {
        self.call::<_, Vec<u32>>(el, ACCESSIBLE, "GetState", &())
            .map(|v| v.first().copied().unwrap_or(0) as u64 | (v.get(1).copied().unwrap_or(0) as u64) << 32)
            .unwrap_or(0)
    }

    pub fn interfaces(&self, el: &El) -> Vec<String> {
        self.call(el, ACCESSIBLE, "GetInterfaces", &()).unwrap_or_default()
    }

    pub fn name(&self, el: &El) -> Option<String> {
        self.prop(el, ACCESSIBLE, "Name").and_then(|v| String::try_from(v).ok()).filter(|s| !s.is_empty())
    }

    pub fn description(&self, el: &El) -> Option<String> {
        self.prop(el, ACCESSIBLE, "Description").and_then(|v| String::try_from(v).ok()).filter(|s| !s.is_empty())
    }

    pub fn attributes(&self, el: &El) -> std::collections::HashMap<String, String> {
        self.call(el, ACCESSIBLE, "GetAttributes", &()).unwrap_or_default()
    }

    /// Screen coordinates (x, y, w, h).
    pub fn extents(&self, el: &El) -> Option<(i32, i32, i32, i32)> {
        self.extents_in(el, coord::SCREEN)
    }

    /// (x, y, w, h) in `coord_type` (`coord::SCREEN` or `coord::WINDOW`). Wayland apps cannot
    /// know where their windows are, so there only window coordinates mean anything.
    pub fn extents_in(&self, el: &El, coord_type: u32) -> Option<(i32, i32, i32, i32)> {
        self.call(el, COMPONENT, "GetExtents", &(coord_type,))
    }

    pub fn grab_focus(&self, el: &El) -> bool {
        self.call::<_, bool>(el, COMPONENT, "GrabFocus", &()).unwrap_or(false)
    }

    /// (name, description, key binding) per action.
    pub fn actions(&self, el: &El) -> Vec<String> {
        self.call::<_, Vec<(String, String, String)>>(el, ACTION, "GetActions", &())
            .unwrap_or_default()
            .into_iter()
            .map(|(n, _, _)| n)
            .collect()
    }

    pub fn do_action(&self, el: &El, index: i32) -> bool {
        self.call::<_, bool>(el, ACTION, "DoAction", &(index,)).unwrap_or(false)
    }

    pub fn character_count(&self, el: &El) -> Option<i32> {
        self.prop(el, TEXT, "CharacterCount").and_then(|v| i32::try_from(v).ok())
    }

    pub fn caret(&self, el: &El) -> Option<i32> {
        self.prop(el, TEXT, "CaretOffset").and_then(|v| i32::try_from(v).ok())
    }

    pub fn text(&self, el: &El) -> Option<String> {
        let n = self.character_count(el)?;
        self.call(el, TEXT, "GetText", &(0i32, n.max(0)))
    }

    pub fn selection(&self, el: &El) -> Option<(i32, i32)> {
        let n: i32 = self.call(el, TEXT, "GetNSelections", &())?;
        if n < 1 {
            return None;
        }
        self.call(el, TEXT, "GetSelection", &(0i32,))
    }

    pub fn select(&self, el: &El, start: i32, end: i32) -> bool {
        let n: i32 = self.call(el, TEXT, "GetNSelections", &()).unwrap_or(0);
        if n > 0 {
            self.call::<_, bool>(el, TEXT, "SetSelection", &(0i32, start, end)).unwrap_or(false)
        } else {
            self.call::<_, bool>(el, TEXT, "AddSelection", &(start, end)).unwrap_or(false)
        }
    }

    pub fn set_caret(&self, el: &El, offset: i32) -> bool {
        self.call::<_, bool>(el, TEXT, "SetCaretOffset", &(offset,)).unwrap_or(false)
    }

    pub fn insert_text(&self, el: &El, position: i32, text: &str) -> bool {
        let len = text.chars().count() as i32;
        self.call::<_, bool>(el, EDITABLE, "InsertText", &(position, text, len)).unwrap_or(false)
    }

    pub fn delete_text(&self, el: &El, start: i32, end: i32) -> bool {
        self.call::<_, bool>(el, EDITABLE, "DeleteText", &(start, end)).unwrap_or(false)
    }

    pub fn set_text(&self, el: &El, text: &str) -> bool {
        self.call::<_, bool>(el, EDITABLE, "SetTextContents", &(text,)).unwrap_or(false)
    }

    pub fn value(&self, el: &El) -> Option<f64> {
        self.prop(el, VALUE, "CurrentValue").and_then(|v| f64::try_from(v).ok())
    }

    pub fn set_value(&self, el: &El, v: f64) -> bool {
        self.conn
            .call_method(Some(el.bus.as_str()), el.path.as_str(), Some(PROPS), "Set", &(VALUE, "CurrentValue", Value::from(v)))
            .is_ok()
    }

    /// Process id behind a bus name.
    pub fn pid_of(&self, bus: &str) -> Option<u32> {
        self.conn
            .call_method(Some("org.freedesktop.DBus"), "/org/freedesktop/DBus", Some("org.freedesktop.DBus"), "GetConnectionUnixProcessID", &(bus,))
            .ok()?
            .body()
            .deserialize()
            .ok()
    }

    pub fn alive(&self, el: &El) -> bool {
        match self.role_name(el) {
            Some(r) => r != "invalid" && !has(self.states(el), state::DEFUNCT),
            None => false,
        }
    }
}
