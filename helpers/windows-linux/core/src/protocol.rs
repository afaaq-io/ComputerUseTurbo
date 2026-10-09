//! Wire protocol: uint32-LE length-framed UTF-8 JSON, JSON-RPC 2.0,
//! `hello` then `request`.

use std::io::{self, Read, Write};

use serde_json::{json, Map, Value};

use crate::agent::AgentIdentity;
use crate::errors::{ErrorCode, TurboError};

pub const API_VERSION: &str = "turbo-1";
pub const HELPER_VERSION: &str = env!("CARGO_PKG_VERSION");
/// Hard frame cap, both directions: 8 MiB.
pub const MAX_FRAME: usize = 8 * 1024 * 1024;
/// Default request deadline when the client omits one.
pub const DEFAULT_DEADLINE_MS: i64 = 120_000;

/// Read one frame. `Ok(None)` on a clean end of stream before a header.
pub fn read_frame<R: Read>(r: &mut R) -> io::Result<Option<Vec<u8>>> {
    let mut header = [0u8; 4];
    let mut got = 0;
    while got < 4 {
        match r.read(&mut header[got..]) {
            Ok(0) if got == 0 => return Ok(None),
            Ok(0) => return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "truncated frame header")),
            Ok(n) => got += n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    let len = u32::from_le_bytes(header) as usize;
    if len == 0 || len > MAX_FRAME {
        return Err(io::Error::new(io::ErrorKind::InvalidData, format!("bad frame length {len}")));
    }
    let mut body = vec![0u8; len];
    r.read_exact(&mut body)?;
    Ok(Some(body))
}

pub fn write_frame<W: Write>(w: &mut W, body: &[u8]) -> io::Result<()> {
    if body.is_empty() || body.len() > MAX_FRAME {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "frame too large"));
    }
    let mut out = Vec::with_capacity(body.len() + 4);
    out.extend_from_slice(&(body.len() as u32).to_le_bytes());
    out.extend_from_slice(body);
    w.write_all(&out)?;
    w.flush()
}

/// JSON-RPC level error (`-326xx`) or a domain error.
#[derive(Clone, Debug, PartialEq)]
pub struct RpcError {
    pub code: i64,
    pub message: String,
    pub name: String,
    pub retryable: bool,
}

impl RpcError {
    pub fn jsonrpc(code: i64, name: &str, message: impl Into<String>) -> Self {
        Self { code, message: message.into(), name: name.into(), retryable: false }
    }
    pub fn parse(message: &str) -> Self {
        Self::jsonrpc(-32700, "parseError", message)
    }
    pub fn invalid_request(message: &str) -> Self {
        Self::jsonrpc(-32600, "invalidRequest", message)
    }
    pub fn method_not_found(message: impl Into<String>) -> Self {
        Self::jsonrpc(-32601, "methodNotFound", message)
    }
    pub fn invalid_params(message: impl Into<String>) -> Self {
        Self::jsonrpc(-32602, "invalidParams", message)
    }
    pub fn to_json(&self) -> Value {
        json!({"code": self.code, "message": self.message, "data": {"name": self.name, "retryable": self.retryable}})
    }
}

impl From<TurboError> for RpcError {
    fn from(e: TurboError) -> Self {
        Self { code: e.code.code(), message: e.message, name: e.code.name().into(), retryable: e.code.retryable() }
    }
}

pub enum Incoming {
    Request { id: i64, method: String, params: Option<Value> },
    Notification,
    Invalid { id: Value, error: RpcError },
}

pub fn parse_message(body: &[u8]) -> Incoming {
    let value: Value = match serde_json::from_slice(body) {
        Ok(v) => v,
        Err(_) => return Incoming::Invalid { id: Value::Null, error: RpcError::parse("Invalid JSON") },
    };
    let Some(obj) = value.as_object() else {
        return Incoming::Invalid {
            id: Value::Null,
            error: RpcError::invalid_request("Request must be a JSON object (batches are not supported)"),
        };
    };
    let echo = match obj.get("id") {
        Some(v @ Value::Number(_)) | Some(v @ Value::String(_)) => v.clone(),
        _ => Value::Null,
    };
    if obj.get("jsonrpc").and_then(Value::as_str) != Some("2.0") {
        return Incoming::Invalid { id: echo, error: RpcError::invalid_request("jsonrpc must be \"2.0\"") };
    }
    let Some(method) = obj.get("method").and_then(Value::as_str).filter(|m| !m.is_empty()) else {
        return Incoming::Invalid { id: echo, error: RpcError::invalid_request("method must be a non-empty string") };
    };
    let params = obj.get("params").cloned();
    if let Some(p) = &params {
        if !(p.is_object() || p.is_array() || p.is_null()) {
            return Incoming::Invalid { id: echo, error: RpcError::invalid_request("params must be an object or array") };
        }
    }
    match obj.get("id") {
        None => Incoming::Notification,
        Some(Value::Number(n)) if n.is_i64() => Incoming::Request { id: n.as_i64().unwrap(), method: method.into(), params },
        _ => Incoming::Invalid { id: echo, error: RpcError::invalid_request("id must be an integer") },
    }
}

pub fn success(id: i64, result: Value) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "result": result})
}

pub fn failure(id: Value, error: &RpcError) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "error": error.to_json()})
}

/// The request types the helper serves.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RequestType {
    AccessStatus,
    RequestAccess,
    FindApps,
    CheckPolicy,
    FinishTurn,
    Reset,
    PreviewPanel,
    ObserveApp,
    Act,
    AppCommands,
    WaitFor,
}

impl RequestType {
    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "accessStatus" => Self::AccessStatus,
            "requestAccess" => Self::RequestAccess,
            "findApps" => Self::FindApps,
            "checkPolicy" => Self::CheckPolicy,
            "finishTurn" => Self::FinishTurn,
            "reset" => Self::Reset,
            "previewPanel" => Self::PreviewPanel,
            "observeApp" => Self::ObserveApp,
            "act" => Self::Act,
            "appCommands" => Self::AppCommands,
            "waitFor" => Self::WaitFor,
            _ => return None,
        })
    }
    pub fn name(self) -> &'static str {
        match self {
            Self::AccessStatus => "accessStatus",
            Self::RequestAccess => "requestAccess",
            Self::FindApps => "findApps",
            Self::CheckPolicy => "checkPolicy",
            Self::FinishTurn => "finishTurn",
            Self::Reset => "reset",
            Self::PreviewPanel => "previewPanel",
            Self::ObserveApp => "observeApp",
            Self::Act => "act",
            Self::AppCommands => "appCommands",
            Self::WaitFor => "waitFor",
        }
    }
}

/// Parsed `request` params.
#[derive(Clone, Debug)]
pub struct Envelope {
    pub request_type: RequestType,
    pub payload: Map<String, Value>,
    pub deadline_ms: i64,
    pub session_id: String,
    pub turn_id: Option<String>,
    pub agent: Option<AgentIdentity>,
}

pub fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

impl Envelope {
    pub fn parse(params: Option<&Value>) -> Result<Self, RpcError> {
        let obj = params.and_then(Value::as_object).ok_or_else(|| RpcError::invalid_params("params must be an object"))?;
        let ty = obj
            .get("requestType")
            .and_then(Value::as_str)
            .ok_or_else(|| RpcError::invalid_params("params.requestType must be a string"))?;
        let request_type =
            RequestType::parse(ty).ok_or_else(|| RpcError::method_not_found(format!("Unknown requestType '{ty}'")))?;
        let payload = match obj.get("payload") {
            None | Some(Value::Null) => Map::new(),
            Some(Value::Object(o)) => o.clone(),
            _ => return Err(RpcError::invalid_params("params.payload must be an object")),
        };
        let deadline_ms = match obj.get("deadlineUnixMillis") {
            None | Some(Value::Null) => now_ms() + DEFAULT_DEADLINE_MS,
            Some(v) => {
                let d = v.as_f64().filter(|d| d.is_finite()).ok_or_else(|| {
                    RpcError::invalid_params("params.deadlineUnixMillis must be a number")
                })?;
                d.clamp(0.0, (i64::MAX / 4) as f64) as i64
            }
        };
        let session = obj
            .get("session")
            .and_then(Value::as_object)
            .ok_or_else(|| RpcError::invalid_params("params.session.sessionId must be a non-empty string"))?;
        let session_id = session
            .get("sessionId")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .ok_or_else(|| RpcError::invalid_params("params.session.sessionId must be a non-empty string"))?
            .to_string();
        Ok(Self {
            request_type,
            payload,
            deadline_ms,
            session_id,
            turn_id: session.get("turnId").and_then(Value::as_str).map(str::to_string),
            agent: AgentIdentity::parse(session.get("agent")),
        })
    }

    pub fn app_query(&self) -> Result<String, TurboError> {
        self.payload
            .get("app")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string)
            .ok_or_else(|| TurboError::bad("payload.app must be an app name, id or absolute path"))
    }

    pub fn expired(&self) -> bool {
        now_ms() >= self.deadline_ms
    }

    pub fn seconds_left(&self) -> f64 {
        (self.deadline_ms - now_ms()) as f64 / 1000.0
    }

    /// Log label: request type, session prefix, app and step type, one line, truncated.
    pub fn log_label(&self) -> String {
        let mut s = format!("{} [session {}]", self.request_type.name(), clean(&self.session_id, 8));
        if let Some(app) = self.payload.get("app").and_then(Value::as_str) {
            s += &format!(" app=\"{}\"", clean(app, 120));
        }
        if let Some(t) = self.payload.get("step").and_then(|s| s.get("type")).and_then(Value::as_str) {
            s += &format!(" step={}", clean(t, 40));
        }
        s
    }
}

/// One line, quotes escaped, truncated (for peer-supplied strings in logs and text).
pub fn clean(s: &str, limit: usize) -> String {
    let mut out = String::new();
    for (i, ch) in s.chars().enumerate() {
        if i >= limit {
            out.push('…');
            break;
        }
        match ch {
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '"' => out.push_str("\\\""),
            c if c.is_control() => {}
            c => out.push(c),
        }
    }
    out
}

impl From<RpcError> for TurboError {
    fn from(e: RpcError) -> Self {
        TurboError::new(ErrorCode::BadArguments, e.message)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frames_round_trip() {
        let mut buf = Vec::new();
        write_frame(&mut buf, b"{\"a\":1}").unwrap();
        assert_eq!(&buf[..4], &[7, 0, 0, 0]);
        let mut r = &buf[..];
        assert_eq!(read_frame(&mut r).unwrap().unwrap(), b"{\"a\":1}");
        assert!(read_frame(&mut r).unwrap().is_none());
    }

    #[test]
    fn envelope_parses_agent() {
        let v = json!({"requestType": "act", "payload": {"app": "x"},
            "session": {"sessionId": "s", "agent": {"name": "my-agent", "hostPid": 42}}});
        let e = Envelope::parse(Some(&v)).unwrap();
        assert_eq!(e.request_type, RequestType::Act);
        assert_eq!(e.agent.unwrap().name, "My Agent");
    }
}
