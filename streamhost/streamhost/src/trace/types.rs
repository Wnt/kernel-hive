//! The two little value types every span is made of, kept out of `mod.rs` so
//! that file stays inside the 500-line Rust soft budget.

/// OTel span kinds, spelled as `traces.py` stores them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Internal,
    Server,
    Client,
}

impl Kind {
    pub(super) fn as_str(self) -> &'static str {
        match self {
            Kind::Internal => "internal",
            Kind::Server => "server",
            Kind::Client => "client",
        }
    }
}

/// One attribute value. Deliberately not `serde_json::Value`: the accepted
/// types are exactly the four `traces.py::_clean_attrs` keeps, and narrowing
/// here means a call site cannot smuggle a nested object past the collector's
/// caps and have it silently dropped at the far end.
#[derive(Debug, Clone)]
pub enum Val {
    S(String),
    I(i64),
    B(bool),
    F(f64),
}

impl From<&str> for Val {
    fn from(v: &str) -> Self {
        Val::S(v.to_string())
    }
}
impl From<String> for Val {
    fn from(v: String) -> Self {
        Val::S(v)
    }
}
impl From<u64> for Val {
    fn from(v: u64) -> Self {
        Val::I(v as i64)
    }
}
impl From<u32> for Val {
    fn from(v: u32) -> Self {
        Val::I(v as i64)
    }
}
impl From<i64> for Val {
    fn from(v: i64) -> Self {
        Val::I(v)
    }
}
impl From<bool> for Val {
    fn from(v: bool) -> Self {
        Val::B(v)
    }
}
impl From<f64> for Val {
    fn from(v: f64) -> Self {
        Val::F(v)
    }
}
