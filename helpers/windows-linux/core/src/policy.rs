//! Safety policy (steps 4–5): the shared `shared/policy.json` (compiled in,
//! overridable with `$CUT_POLICY_FILE` or a `policy.json` next to the executable), the helper
//! itself and the agent's host app, and the user's `allow-protected.txt`.

use std::collections::HashSet;
use std::path::Path;

use serde_json::Value;

const BUILT_IN: &str = include_str!("../../../../shared/policy.json");

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SafetyLists {
    pub protected: Vec<String>,
    pub sensitive: Vec<String>,
}

impl SafetyLists {
    pub fn parse(json: &str, platform: &str) -> Option<Self> {
        let root: Value = serde_json::from_str(json).ok()?;
        let obj = root.as_object()?;
        if !obj.contains_key("protected") && !obj.contains_key("sensitive") {
            return None;
        }
        let list = |key: &str| -> Vec<String> {
            obj.get(key)
                .and_then(|v| v.get(platform))
                .and_then(Value::as_array)
                .map(|a| a.iter().filter_map(Value::as_str).map(str::to_string).collect())
                .unwrap_or_default()
        };
        Some(Self { protected: list("protected"), sensitive: list("sensitive") })
    }

    /// `$CUT_POLICY_FILE`, `policy.json` next to the executable, else the built-in copy.
    pub fn load(platform: &str) -> Self {
        let mut candidates: Vec<std::path::PathBuf> = vec![];
        if let Ok(p) = std::env::var("CUT_POLICY_FILE") {
            if !p.is_empty() {
                candidates.push(p.into());
            }
        }
        if let Ok(exe) = std::env::current_exe() {
            if let Some(dir) = exe.parent() {
                candidates.push(dir.join("policy.json"));
            }
        }
        for c in candidates {
            if let Ok(text) = std::fs::read_to_string(&c) {
                if let Some(l) = Self::parse(&text, platform) {
                    return l;
                }
            }
        }
        Self::parse(BUILT_IN, platform).unwrap_or_default()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Decision {
    Allowed,
    Protected,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Risk {
    Normal,
    Sensitive,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Evaluation {
    pub decision: Decision,
    pub risk: Risk,
    pub reason: Option<String>,
}

pub const HELPER_ID: &str = "computer-use-turbo-helper";

pub struct SafetyPolicy {
    protected: HashSet<String>,
    sensitive: HashSet<String>,
    hosts: HashSet<String>,
    overrides: HashSet<String>,
}

/// App ids are compared case-insensitively; on Windows ids are executable file names
/// (`notepad.exe`), so a `.exe` suffix is optional on either side.
pub fn normalize_id(id: &str) -> String {
    let lower = id.trim().to_lowercase();
    lower.strip_suffix(".exe").map(str::to_string).unwrap_or(lower)
}

impl SafetyPolicy {
    pub fn new(lists: &SafetyLists, host_ids: &[String], overrides: HashSet<String>) -> Self {
        Self {
            protected: lists.protected.iter().map(|s| normalize_id(s)).collect(),
            sensitive: lists.sensitive.iter().map(|s| normalize_id(s)).collect(),
            hosts: host_ids.iter().map(|s| normalize_id(s)).filter(|s| !s.is_empty()).collect(),
            overrides: overrides.iter().map(|s| normalize_id(s)).collect(),
        }
    }

    /// `allow-protected.txt`: ids separated by commas and/or newlines; `#` comments.
    pub fn parse_overrides(text: &str) -> HashSet<String> {
        let mut out = HashSet::new();
        for line in text.lines() {
            let line = line.split('#').next().unwrap_or("");
            for item in line.split(',') {
                let id = item.trim();
                if !id.is_empty() {
                    out.insert(normalize_id(id));
                }
            }
        }
        out
    }

    pub fn load_overrides(path: &Path) -> HashSet<String> {
        std::fs::read_to_string(path).map(|t| Self::parse_overrides(&t)).unwrap_or_default()
    }

    pub fn evaluate(&self, id: &str) -> Evaluation {
        let id = normalize_id(id);
        let risk = if self.sensitive.contains(&id) { Risk::Sensitive } else { Risk::Normal };
        let protected = |reason: &str| Evaluation {
            decision: Decision::Protected,
            risk,
            reason: Some(reason.into()),
        };
        if id == HELPER_ID {
            return protected("Computer Use Turbo cannot operate its own helper.");
        }
        if self.hosts.contains(&id) {
            return protected("This is the app the agent itself runs in; an agent may not control its own host.");
        }
        if self.protected.contains(&id) && !self.overrides.contains(&id) {
            return protected(
                "This app is protected by the safety policy (system authentication, system settings) and cannot be controlled.",
            );
        }
        if risk == Risk::Sensitive {
            return Evaluation {
                decision: Decision::Allowed,
                risk,
                reason: Some("This app manages passwords or other credentials; the user confirms it once per session.".into()),
            };
        }
        Evaluation { decision: Decision::Allowed, risk, reason: None }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn built_in_sections() {
        let w = SafetyLists::parse(BUILT_IN, "windows").unwrap();
        assert!(w.protected.iter().any(|s| s == "consent.exe"));
        assert!(!w.protected.iter().any(|s| s == "cmd.exe"), "terminals can be controlled");
        let l = SafetyLists::parse(BUILT_IN, "linux").unwrap();
        assert!(l.sensitive.iter().any(|s| s == "keepassxc"));
    }

    #[test]
    fn evaluation() {
        let lists = SafetyLists { protected: vec!["cmd.exe".into()], sensitive: vec!["keepassxc".into()] };
        let p = SafetyPolicy::new(&lists, &["Host.exe".into()], SafetyPolicy::parse_overrides("cmd # escape hatch\nhost"));
        assert_eq!(p.evaluate("CMD.EXE").decision, Decision::Allowed); // overridden
        assert_eq!(p.evaluate("host.exe").decision, Decision::Protected); // host never overridable
        assert_eq!(p.evaluate(HELPER_ID).decision, Decision::Protected);
        let k = p.evaluate("keepassxc");
        assert_eq!((k.decision, k.risk), (Decision::Allowed, Risk::Sensitive));
        assert_eq!(p.evaluate("notepad.exe").risk, Risk::Normal);
    }
}
