//! Shared test scaffolding.
//!
//! A module, not a test target: cargo only treats `tests/*.rs` as test binaries,
//! so `tests/common/mod.rs` is pulled in with `mod common;`.

use std::ffi::OsString;
use std::sync::{Mutex, MutexGuard};

/// One lock for the whole test binary. Every test that touches a process-global
/// (environment variables) takes it, so no two tests can observe each other's
/// setup — which is otherwise a silent, order-dependent failure.
static ENV_LOCK: Mutex<()> = Mutex::new(());

/// Sets environment variables for the duration of a test and restores them on
/// drop.
///
/// The stub `dsh` and the anti-nest guard both read process-global state, so
/// tests that set it must not overlap. Holding this guard for the entire test —
/// including any `await` — is the price of a deterministic suite.
pub struct EnvGuard {
    _lock: MutexGuard<'static, ()>,
    previous: Vec<(&'static str, Option<OsString>)>,
}

impl EnvGuard {
    pub fn set(pairs: &[(&'static str, &str)]) -> Self {
        let guard = Self {
            _lock: ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner()),
            previous: pairs.iter().map(|(key, _)| (*key, std::env::var_os(key))).collect(),
        };
        for (key, value) in pairs {
            // SAFETY: every writer in a test binary holds the lock above, and
            // every reader lives in a child process spawned after this point.
            unsafe { std::env::set_var(key, value) };
        }
        guard
    }
}

impl Drop for EnvGuard {
    fn drop(&mut self) {
        for (key, value) in std::mem::take(&mut self.previous) {
            match value {
                Some(value) => unsafe { std::env::set_var(key, value) },
                None => unsafe { std::env::remove_var(key) },
            }
        }
    }
}
