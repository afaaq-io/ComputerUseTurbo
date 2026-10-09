//! Error codes. The numeric values are the wire codes.

use std::fmt;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ErrorCode {
    CallerRejected = 4001,
    AppBlockedByPolicy = 4002,
    AppProtected = 4003,
    AccessMissing = 4004,
    AccessWaiting = 4005,
    AppNameUnclear = 4006,
    StaleElement = 4007,
    HaltedByUser = 4008,
    UserTookOver = 4009,
    DisplayLocked = 4010,
    ProtocolMismatch = 4011,
    TimedOut = 4012,
    AppMissing = 4013,
    NoWindow = 4014,
    ObserveFirst = 4015,
    PasswordGuard = 4016,
    BadArguments = 4017,
    ActionError = 4018,
    NotSupported = 4019,
    HelperFault = 4020,
    UserDeclined = 4021,
    UserActive = 4022,
}

impl ErrorCode {
    pub fn code(self) -> i64 {
        self as i64
    }

    /// The `data.name` string sent on the wire.
    pub fn name(self) -> &'static str {
        use ErrorCode::*;
        match self {
            CallerRejected => "callerRejected",
            AppBlockedByPolicy => "appBlockedByPolicy",
            AppProtected => "appProtected",
            AccessMissing => "accessMissing",
            AccessWaiting => "accessWaiting",
            AppNameUnclear => "appNameUnclear",
            StaleElement => "staleElement",
            HaltedByUser => "haltedByUser",
            UserTookOver => "userTookOver",
            DisplayLocked => "displayLocked",
            ProtocolMismatch => "protocolMismatch",
            TimedOut => "timedOut",
            AppMissing => "appMissing",
            NoWindow => "noWindow",
            ObserveFirst => "observeFirst",
            PasswordGuard => "passwordGuard",
            BadArguments => "badArguments",
            ActionError => "actionError",
            NotSupported => "notSupported",
            HelperFault => "helperFault",
            UserDeclined => "userDeclined",
            UserActive => "userActive",
        }
    }

    pub fn retryable(self) -> bool {
        use ErrorCode::*;
        matches!(
            self,
            AccessWaiting
                | StaleElement
                | DisplayLocked
                | TimedOut
                | NoWindow
                | ObserveFirst
                | ActionError
                | HelperFault
                | UserActive
                | UserTookOver
        )
    }
}

/// A domain error raised anywhere in the helper; converted to a JSON-RPC error at the edge.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TurboError {
    pub code: ErrorCode,
    pub message: String,
}

impl TurboError {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Self { code, message: message.into() }
    }

    pub fn bad(message: impl Into<String>) -> Self {
        Self::new(ErrorCode::BadArguments, message)
    }

    pub fn fault(message: impl Into<String>) -> Self {
        Self::new(ErrorCode::HelperFault, message)
    }

    pub fn action(message: impl Into<String>) -> Self {
        Self::new(ErrorCode::ActionError, message)
    }

    pub const HALTED_MESSAGE: &'static str =
        "The user stopped Computer Use. Do not retry; ask the user how to proceed.";

    pub fn halted() -> Self {
        Self::new(ErrorCode::HaltedByUser, Self::HALTED_MESSAGE)
    }

    pub fn stale(index: usize) -> Self {
        Self::new(
            ErrorCode::StaleElement,
            format!("Element #{index} is no longer available; re-run observe_app and use a current number."),
        )
    }
}

impl fmt::Display for TurboError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} ({}): {}", self.code.name(), self.code.code(), self.message)
    }
}

impl std::error::Error for TurboError {}

pub type TurboResult<T> = Result<T, TurboError>;
