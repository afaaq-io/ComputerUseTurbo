//! Computer Use Turbo — platform-neutral core of the Windows and Linux helpers.
//!
//! Everything here is shared with the macOS helper's behaviour and knows nothing about a particular
//! operating system: the wire protocol, error codes, the safety policy, the
//! agent identity, key chords, the UI tree text format (numbered lines, M/A/D changes),
//! screenshot scaling and the request pipeline (`Service`). A platform layer implements
//! [`platform::Platform`] and [`ui::Ui`]; the service does the rest.

pub mod agent;
pub mod b64;
pub mod errors;
pub mod events;
pub mod image_util;
pub mod keys;
pub mod log;
pub mod paths;
pub mod platform;
pub mod policy;
pub mod protocol;
pub mod service;
pub mod session;
pub mod steps;
pub mod texts;
pub mod tree;
pub mod ui;

pub use errors::{ErrorCode, TurboError};
