//! The helper's own UI: the confirmation card for password managers, the status overlay
//! with Stop, and the live preview. Implemented by the helper binary.

use crate::platform::Rect;

/// The user's answer on the password-manager card.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Choice {
    Once,
    Session,
    Deny,
    /// The card could not be shown (no usable graphics): nobody was asked.
    Unavailable,
}

impl Choice {
    pub fn parse(s: &str) -> Choice {
        match s.trim() {
            "once" => Choice::Once,
            "session" => Choice::Session,
            _ => Choice::Deny,
        }
    }
}

#[derive(Clone, Debug)]
pub struct ApprovalRequest {
    pub agent: String,
    pub app_name: String,
    pub app_id: String,
    pub app_path: String,
    pub timeout_secs: u64,
}

#[derive(Clone, Debug, PartialEq)]
pub enum OverlayState {
    Active { agent: String, app: String },
    Stopped,
    Hidden,
}

#[derive(Clone, Debug)]
pub enum PreviewUpdate {
    /// A JPEG frame of the target window and where the agent's (host's) window is: the panel
    /// hangs in its top-right corner; None = docked under the status overlay (the agent's
    /// window exists but its place on screen is not known).
    Frame { jpeg: Vec<u8>, width: u32, height: u32, anchor: Option<Rect>, app: String },
    Hide,
}

pub trait Ui: Send + Sync {
    /// Blocks until the user answers or the timeout passes (→ Deny).
    fn ask(&self, request: &ApprovalRequest) -> Choice;
    fn overlay(&self, state: OverlayState);
    fn preview(&self, update: PreviewUpdate);
}

/// A UI that shows nothing and denies every confirmation (tests, headless use).
pub struct NoUi;

impl Ui for NoUi {
    fn ask(&self, _: &ApprovalRequest) -> Choice {
        Choice::Deny
    }
    fn overlay(&self, _: OverlayState) {}
    fn preview(&self, _: PreviewUpdate) {}
}
