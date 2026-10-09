//! Who is driving the helper (`session.agent`): a display name the MCP
//! client reported for itself and the app the agent runs in. Never a built-in list of names.

use std::sync::Mutex;

use serde_json::Value;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentIdentity {
    pub name: String,
    pub host_pid: Option<u32>,
    pub host_app_path: Option<String>,
    /// Ancestors of the server process, nearest first: the platform picks the nearest one
    /// that owns a top-level window as the host.
    pub ancestor_pids: Vec<u32>,
}

pub const FALLBACK_NAME: &str = "Your AI agent";
const MAX_NAME: usize = 40;

impl AgentIdentity {
    pub fn unknown() -> Self {
        Self { name: FALLBACK_NAME.into(), host_pid: None, host_app_path: None, ancestor_pids: vec![] }
    }

    pub fn parse(value: Option<&Value>) -> Option<Self> {
        let o = value?.as_object()?;
        let mut id = Self::unknown();
        id.name = display_name(o.get("name").and_then(Value::as_str));
        id.host_pid = o.get("hostPid").and_then(Value::as_u64).filter(|p| *p > 0 && *p <= u32::MAX as u64).map(|p| p as u32);
        id.host_app_path = o.get("hostAppPath").and_then(Value::as_str).map(str::to_string);
        id.ancestor_pids = o
            .get("ancestorPids")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_u64).filter(|p| *p > 0 && *p <= u32::MAX as u64).map(|p| p as u32).take(32).collect())
            .unwrap_or_default();
        Some(id)
    }
}

/// A readable display name: control characters dropped, kebab / snake case → "Title Words",
/// at most 40 characters; empty → the fallback.
pub fn display_name(raw: Option<&str>) -> String {
    let Some(raw) = raw else { return FALLBACK_NAME.into() };
    let mut s: String = raw.chars().filter(|c| !c.is_control()).collect::<String>().trim().to_string();
    if !s.contains(' ') && s.contains(['-', '_']) {
        s = s
            .split(['-', '_'])
            .filter(|w| !w.is_empty())
            .map(|w| {
                let mut c = w.chars();
                match c.next() {
                    Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
                    None => String::new(),
                }
            })
            .collect::<Vec<_>>()
            .join(" ");
    } else if let Some(first) = s.chars().next() {
        if first.is_lowercase() {
            s = first.to_uppercase().collect::<String>() + &s[first.len_utf8()..];
        }
    }
    if s.chars().count() > MAX_NAME {
        s = s.chars().take(MAX_NAME - 1).collect::<String>() + "…";
    }
    if s.is_empty() {
        FALLBACK_NAME.into()
    } else {
        s
    }
}

/// The identity of the most recent request (UI not tied to one request uses it).
pub struct AgentRegistry {
    value: Mutex<AgentIdentity>,
}

impl AgentRegistry {
    pub fn new() -> Self {
        Self { value: Mutex::new(AgentIdentity::unknown()) }
    }
    pub fn current(&self) -> AgentIdentity {
        self.value.lock().unwrap().clone()
    }
    pub fn update(&self, id: AgentIdentity) {
        *self.value.lock().unwrap() = id;
    }
}

impl Default for AgentRegistry {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names() {
        assert_eq!(display_name(Some("my-agent_cli")), "My Agent Cli");
        assert_eq!(display_name(Some("Desk Agent")), "Desk Agent");
        assert_eq!(display_name(Some("  \n")), FALLBACK_NAME);
        assert_eq!(display_name(None), FALLBACK_NAME);
        assert_eq!(display_name(Some(&"x".repeat(80))).chars().count(), 40);
    }
}
