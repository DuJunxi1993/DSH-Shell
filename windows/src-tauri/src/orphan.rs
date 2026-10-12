//! Finding a dsh that outlived the shell that started it.
//!
//! `starting_pid` covers the one orphan this shell can be responsible for: the
//! gap between "spawn returned a PID" and "the handle is owned". It cannot cover
//! an orphan from a *previous* run — a crash, a kill, a laptop lid, or the shell
//! being upgraded out from under a running dsh. Those hold the port, and the next
//! launch then refuses to start with "port in use", pointing the user at `attach`
//! for a dsh nobody wants.
//!
//! Reclaiming one means killing a process this shell never spawned, which is the
//! most dangerous thing in this repository. So a candidate must satisfy **three
//! independent facts**, and any one of them failing leaves the process alone:
//!
//! 1. it owns the port our own config asked for;
//! 2. it has no living parent — it was orphaned, rather than being something the
//!    operator is sitting in right now;
//! 3. it is running the harness from the `dsh_binary_path` we are configured to.
//!
//! Fact 2 is what makes this safe and it is the one that is easy to leave out. On
//! a developer machine the port is *usually* held by something in use, and the
//! operator is usually in it: a dsh this shell orphaned and a dsh the operator
//! launched from a terminal both hold the port, both are `node.exe`, and both
//! have a command line that mentions dsh. The parent is what tells them apart,
//! and it is measurable.
//!
//! Fact 3 has to be checked against the **command line**, not the executable.
//! `dsh_binary_path` is an npm shim — `dsh.cmd` — while the thing actually
//! holding the port is `node.exe`, so every real dsh was being refused by a
//! comparison that could never succeed. The shim and the harness package are
//! siblings under the same npm prefix, so the harness directory is derived from
//! the shim and looked for in the command line; that distinguishes "this dsh"
//! from "some other node process that happens to listen on that port".
//!
//! # Two ways this silently did nothing
//!
//! Both were live bugs, and both are now covered by tests that fail if the
//! behaviour regresses:
//!
//! - Requiring `parent_pid == 1` rejected every real orphan. Windows keeps the
//!   dead parent's PID in the snapshot rather than reparenting to 1, so an
//!   orphaned dsh reports a PID that no longer exists. The test is now "no
//!   *living* parent", with PID 1 as a special case of that.
//! - Comparing executable file names rejected every real dsh, as above.

/// What is known about a process that holds a port.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProcessInfo {
    pub pid: u32,
    pub parent_pid: u32,
    /// Whether `parent_pid` names a process that still exists.
    ///
    /// Carried rather than reduced to a bool so the refusal messages can say
    /// *why*: "it still has a parent" and "its parent is gone" are different
    /// answers, and only one of them is a reason to stop.
    pub parent_alive: bool,
    /// The process's full command line, as Windows reports it.
    pub command_line: String,
}

/// The rule behind [`reclaim_orphan`], as a pure function so the decision can be
/// tested without spawning, killing, or inspecting anything.
///
/// Returns the process when it may be reclaimed, and the reason when it may not.
/// A reason rather than a bool, because the only thing that makes an unexplained
/// refusal debuggable is being told what was missing.
pub fn is_reclaimable_orphan(
    port: u16,
    config_port: u16,
    info: &ProcessInfo,
    configured_binary: &std::path::Path,
) -> Result<(), &'static str> {
    if config_port == 0 {
        return Err("the port was chosen by the system, not by us, so it identifies nothing");
    }
    // "No parent" means two different things that both count. PID 1 is the
    // system-wide reaper on Linux and shows up on Windows for some processes; a
    // dead PID is what an orphan left behind on Windows actually looks like,
    // because the parent PID is recorded rather than cleared. Both are handled by
    // asking whether the parent is *alive*, which also fails safe: if the PID was
    // recycled onto an unrelated process the parent counts as alive and we leave
    // the candidate alone.
    if info.parent_pid != 1 && info.parent_alive {
        return Err("it still has a parent, so something is using it");
    }
    let Some(harness) = harness_marker(configured_binary) else {
        return Err("the configured dsh path does not look like an npm shim");
    };
    // Case-insensitive, and matched on a path fragment rather than the whole
    // string: the command line quotes and escapes its own arguments, and the
    // casing of the npm prefix varies by machine.
    if !info
        .command_line
        .to_lowercase()
        .contains(&harness.to_lowercase())
    {
        return Err("it is not running the dsh this shell is configured to");
    }
    // The port is the subject of the query, so it is checked last: it is the fact
    // least likely to be wrong, and the most likely to be about the wrong thing.
    if port != config_port {
        return Err("it is not on the port we asked for");
    }
    Ok(())
}

/// The path fragment that identifies this installation's harness in a command
/// line.
///
/// `dsh_binary_path` points at an npm shim, `...\npm\dsh.cmd`, and the process
/// that ends up holding the port is `node.exe` running a script inside
/// `...\npm\node_modules\@deepseek-ai\dsh\`. The shim and the package share a
/// parent directory, so the package directory is derived from the shim's rather
/// than guessed from the package name alone — a different npm prefix on the same
/// machine must not produce a marker that matches someone else's install.
///
/// `None` when the configured path has no parent directory to derive it from,
/// which is the signal to refuse rather than to fall back to a loose match.
fn harness_marker(configured_binary: &std::path::Path) -> Option<String> {
    // `Path::new("dsh.cmd").parent()` is `Some("")`, not `None`, so the empty
    // case has to be excluded explicitly. Deriving a marker from it would produce
    // the relative path `node_modules\@deepseek-ai\dsh`, which would then match
    // any dsh on the machine — the opposite of what this function is for.
    let prefix = configured_binary.parent().filter(|p| !p.as_os_str().is_empty())?;
    Some(
        prefix
            .join("node_modules")
            .join("@deepseek-ai")
            .join("dsh")
            .to_string_lossy()
            .into_owned(),
    )
}

/// Whether the process holding `port` is an orphan this shell may reclaim.
///
/// Returns the process when it may be killed, and the reason when it may not.
/// Nothing here kills anything; the caller decides what to do with the answer.
pub fn classify_port_occupant(
    port: u16,
    config: &crate::config::Config,
) -> Result<ProcessInfo, String> {
    let owner = process_listening_on(port)
        .ok_or_else(|| format!("nothing is listening on {port}, so there is nothing to reclaim"))?;

    let parent_pid = parent_of(owner)
        .ok_or_else(|| format!("could not read the parent of pid {owner}"))?;
    // Read the parent *before* deciding, because "the parent PID is a number
    // that still exists" is the question that matters and it is not the same as
    // "the parent PID is 1". If the snapshot cannot answer, we say so rather than
    // assuming either way.
    let parent_alive = match process_exists(parent_pid) {
        Some(alive) => alive,
        None => {
            return Err(format!(
                "could not tell whether the parent of pid {owner} is still alive"
            ))
        }
    };
    let command_line = command_line_of(owner).ok_or_else(|| {
        format!(
            "could not read the command line of pid {owner}, so there is no way to \
             confirm it is this shell's dsh"
        )
    })?;

    let info = ProcessInfo {
        pid: owner,
        parent_pid,
        parent_alive,
        command_line,
    };
    match is_reclaimable_orphan(port, config.preferred_port, &info, &config.dsh_binary_path) {
        Ok(()) => Ok(info),
        Err(reason) => Err(format!("pid {owner} holds {port} but {reason}")),
    }
}

/// Reclaim an orphan dsh left by a previous run, if one is there.
///
/// Deliberately silent when there is nothing to do: a port nobody holds is the
/// normal case, and a log line for it on every launch would be noise that trains
/// the reader to skip the log.
///
/// `why` is only ever the log line's own context, never the decision: the rule
/// that decides whether to kill is [`is_reclaimable_orphan`], and it is the same
/// rule at launch and at exit. That is deliberate — two code paths that "mostly
/// agree" about which processes we are allowed to kill is how a shell ends up
/// killing somebody's server on one path and not the other.
#[cfg(windows)]
pub fn reclaim_orphan(config: &crate::config::Config, why: ReclaimReason) {
    use crate::config::LaunchMode;
    use crate::preflight::port_is_free;

    if config.launch_mode != LaunchMode::Spawn || config.preferred_port == 0 {
        return;
    }
    // The free check is the cheap way out: on a healthy launch nothing is
    // listening, and the enumeration below only runs when it is not.
    if port_is_free(&config.listen_host, config.preferred_port) {
        return;
    }
    match classify_port_occupant(config.preferred_port, config) {
        Ok(info) => {
            tracing::warn!(
                target: "dsh_shell",
                "{}: reclaiming an orphaned dsh (pid {}, parent {}, now {}) on port {}: {}",
                why.log_prefix(),
                info.pid,
                info.parent_pid,
                if info.parent_alive { "alive" } else { "gone" },
                config.preferred_port,
                info.command_line
            );
            crate::platform::terminate_tree_sync(info.pid);
        }
        Err(reason) => {
            // Not an error: the port may be held by something legitimate.
            tracing::info!(
                target: "dsh_shell",
                "{}: leaving the port alone: {reason}",
                why.log_prefix()
            );
        }
    }
}

/// Which end of the shell's life asked for a reclaim.
///
/// Carries the log wording and nothing else — see [`reclaim_orphan`] for why the
/// two call sites deliberately share one decision.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReclaimReason {
    /// Start-up, before the first spawn: a dsh an earlier run left behind is
    /// holding the port this launch needs.
    AtStartup,
    /// Shutdown, after our own child has been terminated: something is *still*
    /// holding our port, which means our tree kill missed something.
    AtExit,
}

impl ReclaimReason {
    fn log_prefix(self) -> &'static str {
        match self {
            ReclaimReason::AtStartup => "startup",
            ReclaimReason::AtExit => "exit",
        }
    }
}

#[cfg(not(windows))]
pub fn reclaim_orphan(_config: &crate::config::Config, _why: ReclaimReason) {}

/// The PID listening on `port`, if any.
///
/// Read out of `netstat -ano` rather than by walking `GetExtendedTcpTable`'s
/// buffer directly. The Win32 route is the "right" API and was written first; it
/// is not used because its row layout is easy to get subtly wrong — the port
/// lives in the high half of a byte-swapped word — and getting it wrong does not
/// fail loudly, it returns nothing and the reclaim silently never happens. A
/// test bound a real listener and proved the hand-rolled version could not see
/// it.
///
/// Spawning a process is normally too heavy for this, and it would be if it
/// mattered: it runs once, at startup, and only when the port is already taken.
/// Correctness of a safety-critical decision is worth more than the spawn.
#[cfg(windows)]
fn process_listening_on(port: u16) -> Option<u32> {
    let output = std::process::Command::new("netstat")
        .args(["-ano"])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&output.stdout);

    for line in text.lines() {
        // Only listening sockets: an established connection to our port is a
        // client, not the server, and reclaiming a client would be a new and very
        // stupid way to break somebody's session.
        if !line.contains("LISTENING") && !line.contains("侦听") {
            continue;
        }
        let mut fields = line.split_whitespace();
        let _proto = fields.next()?;
        let local = fields.next()?;
        let _foreign = fields.next()?;
        let _state = fields.next()?;
        let pid: u32 = match fields.next()?.parse() {
            Ok(pid) => pid,
            Err(_) => continue,
        };
        // The local address is `addr:port`, and the port is after the last colon
        // so that an IPv6 address, which carries colons of its own, still works.
        let listening_port = local.rsplit(':').next()?.parse::<u16>().ok()?;
        if listening_port == port {
            return Some(pid);
        }
    }
    None
}

#[cfg(not(windows))]
fn process_listening_on(_port: u16) -> Option<u32> {
    None
}

/// The parent of `pid`.
///
/// Windows 11 also reports a "parent" for a process whose real parent has already
/// exited, which can be a stale PID. That is not a contradiction — it is exactly
/// what an orphan looks like — so this returns the recorded PID and leaves the
/// judgement to [`process_exists`].
#[cfg(windows)]
fn parent_of(pid: u32) -> Option<u32> {
    use windows::Win32::Foundation::CloseHandle;
    use windows::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W,
        TH32CS_SNAPPROCESS,
    };

    unsafe {
        let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0).ok()?;
        let mut entry = PROCESSENTRY32W {
            dwSize: std::mem::size_of::<PROCESSENTRY32W>() as u32,
            ..Default::default()
        };
        let mut parent = None;
        let mut ok = Process32FirstW(snapshot, &mut entry).is_ok();
        while ok {
            if entry.th32ProcessID == pid {
                parent = Some(entry.th32ParentProcessID);
                break;
            }
            ok = Process32NextW(snapshot, &mut entry).is_ok();
        }
        let _ = CloseHandle(snapshot);
        parent
    }
}

#[cfg(not(windows))]
fn parent_of(_pid: u32) -> Option<u32> {
    None
}

/// Whether a process with this PID is still running.
///
/// `None` when the question could not be answered, which the caller must treat as
/// "do not kill" — an unanswered question is not a yes. PID reuse is handled for
/// free: if the number has been recycled onto an unrelated process this returns
/// true and the candidate is left alone, which is the safe direction to be wrong
/// in.
#[cfg(windows)]
fn process_exists(pid: u32) -> Option<bool> {
    use windows::Win32::Foundation::CloseHandle;
    use windows::Win32::System::Threading::{OpenProcess, WaitForSingleObject, PROCESS_SYNCHRONIZE};

    // The three results `WaitForSingleObject` can give with a zero timeout.
    const WAIT_OBJECT_0: u32 = 0;
    const WAIT_TIMEOUT: u32 = 0x102;
    const WAIT_FAILED: u32 = 0xFFFF_FFFF;

    unsafe {
        // Query-limited information is not enough to *wait* on, so this asks for
        // SYNCHRONIZE. A process that has exited but not been reaped still opens,
        // and the wait returns immediately for it - which is the answer we want,
        // since an exited parent is not a live one.
        let handle = OpenProcess(PROCESS_SYNCHRONIZE, false, pid).ok()?;
        let result = WaitForSingleObject(handle, 0);
        let _ = CloseHandle(handle);
        match result.0 {
            // Signalled: the process has exited, so this parent is gone.
            WAIT_OBJECT_0 => Some(false),
            // Not signalled: still running.
            WAIT_TIMEOUT => Some(true),
            // Anything else is an answer we could not get.
            _ => {
                let _ = WAIT_FAILED;
                None
            }
        }
    }
}

#[cfg(not(windows))]
fn process_exists(_pid: u32) -> Option<bool> {
    None
}

/// The full command line of `pid`.
///
/// This is the only thing that distinguishes "this shell's dsh" from "some other
/// `node.exe` that happens to listen on that port", because the executable alone
/// says nothing: every JavaScript process on the machine is `node.exe`.
///
/// `QueryFullProcessImageNameW` is the Win32 answer and it returns the
/// executable, not the arguments. The command line needs
/// `NtQueryInformationProcess` with information class 60
/// (`ProcessCommandLineInformation`), which is not in any published version of the
/// `windows` crate — it is an ntdll routine, stable since Vista but never
/// surfaced in the Win32 headers — so it is declared here.
///
/// The buffer the call writes is a `UNICODE_STRING` whose own length is updated
/// on the way out; it is a self-describing allocation made by ntdll, so it is
/// freed with `RtlFreeHeap`-equivalent semantics left to the OS, and only the
/// *contents* are copied out. The first call passes null to learn the size, which
/// is the documented contract.
#[cfg(windows)]
fn command_line_of(pid: u32) -> Option<String> {
    use std::ffi::c_void;

    use windows::Win32::Foundation::CloseHandle;
    use windows::Win32::System::Threading::{
        OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
    };

    // PROCESS_COMMAND_LINE_INFORMATION. A NTSTATUS of 0 is success; anything else
    // is a failure and is reported as None so the caller refuses.
    const PROCESS_COMMAND_LINE_INFORMATION: i32 = 60;
    /// `STATUS_INFO_LENGTH_MISMATCH` — the documented answer to a size query with
    /// a null buffer.
    const STATUS_INFO_LENGTH_MISMATCH: i32 = 0xC000_0004u32 as i32;
    /// `STATUS_BUFFER_TOO_SMALL` — the same answer from some builds.
    const STATUS_BUFFER_TOO_SMALL: i32 = 0xC000_0023u32 as i32;
    /// `sizeof(UNICODE_STRING)` on x64: Length, MaximumLength, four bytes of
    /// padding, then the pointer.
    const UNICODE_STRING_SIZE: usize = 16;

    fn size_query_succeeded(status: i32) -> bool {
        status == 0 || status == STATUS_INFO_LENGTH_MISMATCH || status == STATUS_BUFFER_TOO_SMALL
    }

    #[repr(C)]
    struct UnicodeString {
        length: u16,
        maximum_length: u16,
        /// Points into the *target* process's address space. Never dereferenced:
        /// reading it from another process needs `PROCESS_VM_READ` and crashed the
        /// test binary with an access violation before this was noticed.
        buffer: *const u16,
    }

    // Not declared in the `windows` crate at any version: there is no `unsafe
    // extern` block for ntdll in it, and the `windows_targets` link library does
    // not re-export it.
    unsafe extern "system" {
        fn NtQueryInformationProcess(
            process: isize,
            information_class: i32,
            information: *mut c_void,
            information_length: u32,
            return_length: *mut u32,
        ) -> i32;
    }

    unsafe {
        let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;

        // Size query: null buffer, asking only how much would be needed. The
        // answer is STATUS_INFO_LENGTH_MISMATCH, not success - that is how this
        // call says "I would need N bytes". Treating any non-zero status as
        // failure is what made the first version of this function return None for
        // every process, and therefore never reclaim anything.
        let mut needed: u32 = 0;
        let status = NtQueryInformationProcess(
            handle.0 as isize,
            PROCESS_COMMAND_LINE_INFORMATION,
            std::ptr::null_mut(),
            0,
            &mut needed,
        );
        if !size_query_succeeded(status) || needed == 0 {
            let _ = CloseHandle(handle);
            return None;
        }

        let mut buffer = vec![0u8; needed as usize];
        let status = NtQueryInformationProcess(
            handle.0 as isize,
            PROCESS_COMMAND_LINE_INFORMATION,
            buffer.as_mut_ptr().cast(),
            needed,
            &mut needed,
        );
        let _ = CloseHandle(handle);
        if status != 0 {
            return None;
        }

        // The structure ntdll writes is a `UNICODE_STRING` at offset 0 followed by
        // the string's own bytes — the returned size is `16 + maximum_length`,
        // which is how the inline copy was confirmed rather than assumed. The
        // `buffer` field inside it points into the *target* process and is not
        // touched; an earlier version followed that pointer and took the whole
        // test binary down with an access violation.
        if buffer.len() < UNICODE_STRING_SIZE {
            return None;
        }
        let command_line = &*(buffer.as_ptr() as *const UnicodeString);
        let text_at = UNICODE_STRING_SIZE;
        let available = buffer.len().saturating_sub(text_at);
        // Clamped to what we actually allocated, so a length the kernel reports
        // larger than the buffer it just filled cannot walk off the end.
        let wanted = usize::from(command_line.length);
        let bytes = wanted.min(available) & !1;
        if bytes == 0 {
            return None;
        }
        let start = text_at;
        let end = start + bytes;
        let chars: Vec<u16> = buffer[start..end]
            .chunks_exact(2)
            .map(|pair| u16::from_le_bytes([pair[0], pair[1]]))
            .collect();
        Some(String::from_utf16_lossy(&chars))
    }
}

#[cfg(not(windows))]
fn command_line_of(_pid: u32) -> Option<String> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    /// A configured dsh: an npm shim, which is what `dsh_binary_path` actually
    /// holds.
    const SHIM: &str = r"C:\Users\x\AppData\Roaming\npm\dsh.cmd";
    /// The harness package directory derived from [`SHIM`].
    const HARNESS: &str =
        r"C:\Users\x\AppData\Roaming\npm\node_modules\@deepseek-ai\dsh";

    /// What a real orphaned dsh looks like. Not a fixture chosen to pass: this is
    /// the shape that used to be *refused*, twice over. The executable is
    /// `node.exe` rather than `dsh.cmd`, and the parent is a dead PID rather than
    /// 1 — which is what Windows leaves behind when the shell that started it is
    /// killed.
    fn orphan() -> ProcessInfo {
        ProcessInfo {
            pid: 4242,
            parent_pid: 3176,
            parent_alive: false,
            command_line: format!(
                r"C:\Program Files\nodejs\node.exe {HARNESS}\lib\bin.js web --port 3080"
            ),
        }
    }

    #[test]
    fn an_orphaned_configured_dsh_is_reclaimable() {
        assert!(is_reclaimable_orphan(3080, 3080, &orphan(), Path::new(SHIM)).is_ok());
    }

    /// The regression that made the whole module inert. `node.exe` never equals
    /// `dsh.cmd`, so an executable comparison refused every real dsh, and the
    /// feature looked like it was working because the refusal was logged at info.
    #[test]
    fn the_harness_is_matched_on_the_command_line_not_the_executable() {
        let info = orphan();
        // The shim is a .cmd; the thing holding the port is not, and never was.
        assert!(
            info.command_line.contains("node.exe"),
            "the fixture must not be softened into something that passes trivially"
        );
        assert!(
            is_reclaimable_orphan(3080, 3080, &info, Path::new(SHIM)).is_ok(),
            "a node.exe running our harness is our dsh"
        );
    }

    /// The other half of the same bug. Windows records the dead parent's PID in
    /// the process snapshot rather than reparenting to 1, so requiring
    /// `parent_pid == 1` rejected every orphan on the platform.
    #[test]
    fn a_dead_parent_counts_as_orphaned_even_when_it_is_not_pid_one() {
        let mut info = orphan();
        info.parent_pid = 999_999;
        info.parent_alive = false;
        assert!(is_reclaimable_orphan(3080, 3080, &info, Path::new(SHIM)).is_ok());
    }

    #[test]
    fn pid_one_still_counts_as_orphaned() {
        // The case the old check got right, kept so it is not lost with it.
        let mut info = orphan();
        info.parent_pid = 1;
        info.parent_alive = false;
        assert!(is_reclaimable_orphan(3080, 3080, &info, Path::new(SHIM)).is_ok());
    }

    #[test]
    fn a_process_with_a_live_parent_is_never_reclaimed() {
        // The fact that makes this safe: a dsh the operator launched from a
        // terminal has a real parent and is in use.
        let mut info = orphan();
        info.parent_pid = 12345;
        info.parent_alive = true;
        let reason = is_reclaimable_orphan(3080, 3080, &info, Path::new(SHIM))
            .expect_err("must refuse");
        assert!(reason.contains("parent"), "{reason}");
    }

    /// A recycled parent PID points at a *different, living* process. The number
    /// is not 1 and it exists, so the candidate looks like it has a parent - which
    /// is the answer we must give, because we cannot tell it apart from a real
    /// parent and the cost of guessing wrong is killing someone's live server.
    #[cfg(windows)]
    #[test]
    fn a_recycled_parent_pid_is_treated_as_a_live_parent() {
        // `GetCurrentProcessId` exists, so use a PID that is certainly running:
        // this test process's own parent is a shell that is still alive.
        let mut info = orphan();
        info.parent_pid = std::process::id();
        info.parent_alive = true;
        assert!(is_reclaimable_orphan(3080, 3080, &info, Path::new(SHIM)).is_err());
    }

    #[test]
    fn a_different_program_is_never_reclaimed() {
        // Same port, same orphan shape. Somebody else's server is not ours to
        // kill, and "it is node" is not enough - there are a great many.
        let mut info = orphan();
        info.command_line = r"C:\tools\postgres.exe -p 3080".to_string();
        let reason = is_reclaimable_orphan(3080, 3080, &info, Path::new(SHIM))
            .expect_err("must refuse");
        assert!(reason.contains("configured to"), "{reason}");
    }

    /// Another node process, serving something else entirely. This is the case
    /// the executable check could never have caught and the command line can.
    #[test]
    fn another_node_process_on_the_same_port_is_not_reclaimed() {
        let mut info = orphan();
        info.command_line = r"C:\Program Files\nodejs\node.exe C:\app\server.js".to_string();
        assert!(is_reclaimable_orphan(3080, 3080, &info, Path::new(SHIM)).is_err());
    }

    /// A dsh from a *different* npm prefix, on the same machine. The marker is
    /// derived from our own shim rather than being the package name, so an
    /// unrelated install cannot match it by accident.
    #[test]
    fn another_install_of_dsh_is_not_reclaimed() {
        let mut info = orphan();
        info.command_line =
            r"C:\node.exe C:\other\npm\node_modules\@deepseek-ai\dsh\lib\bin.js web".to_string();
        assert!(is_reclaimable_orphan(3080, 3080, &info, Path::new(SHIM)).is_err());
    }

    #[test]
    fn a_system_assigned_port_identifies_nothing() {
        // preferred_port == 0 means the OS picked it, so "the port we asked for"
        // is not evidence of anything.
        assert!(is_reclaimable_orphan(5000, 0, &orphan(), Path::new(SHIM)).is_err());
    }

    #[test]
    fn a_port_other_than_ours_identifies_nothing() {
        // The port we asked for and the port we found are not the same, so
        // whichever this process is, it is not the dsh this launch is waiting for.
        let mut info = orphan();
        info.command_line = format!(
            r"C:\Program Files\nodejs\node.exe {HARNESS}\lib\bin.js web --port 9999"
        );
        let reason =
            is_reclaimable_orphan(9999, 3080, &info, Path::new(SHIM)).expect_err("must refuse");
        assert!(reason.contains("port we asked for"), "{reason}");
    }

    #[test]
    fn a_shim_with_no_directory_to_derive_a_marker_from_is_refused() {
        // Refuse rather than fall back to a loose match on the package name.
        let bare = Path::new("dsh.cmd");
        assert!(harness_marker(bare).is_none());
        assert!(is_reclaimable_orphan(3080, 3080, &orphan(), bare).is_err());
    }

    #[test]
    fn the_marker_is_derived_from_our_own_npm_prefix() {
        let marker = harness_marker(Path::new(SHIM)).expect("a shim in a directory has one");
        assert_eq!(marker, HARNESS);
    }

    #[test]
    fn the_marker_match_ignores_windows_path_casing() {
        let mut info = orphan();
        info.command_line = info.command_line.to_lowercase();
        assert!(
            is_reclaimable_orphan(3080, 3080, &info, Path::new(SHIM)).is_ok(),
            "npm prefixes vary in casing between machines"
        );
    }

    /// Whether the port lookup actually finds a live listener.
    ///
    /// Without this, every test above is a rule about data that was never
    /// collected: the decision function can be perfect and the module still
    /// reclaiming nothing, forever, silently. It binds a real socket and asks the
    /// lookup about it — so if the parse is wrong, this fails rather than the
    /// feature quietly doing nothing in the field.
    #[cfg(windows)]
    #[test]
    fn the_port_lookup_finds_a_live_listener() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind an ephemeral port");
        let port = listener.local_addr().expect("addr").port();
        assert_eq!(
            process_listening_on(port),
            Some(std::process::id()),
            "the port is held by this process and must be found as such"
        );
    }

    #[cfg(windows)]
    #[test]
    fn an_unused_port_has_no_owner() {
        // The other half: a lookup that always answered would pass the test above
        // and reclaim whatever it liked.
        let port = {
            let probe = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
            let port = probe.local_addr().expect("addr").port();
            drop(probe);
            port
        };
        assert_eq!(process_listening_on(port), None, "nothing is listening");
    }

    /// The two measurements the decision rests on, checked against the real
    /// process table rather than a fixture. This is the one that caught the first
    /// version: `image_of` answered correctly for a live process, and was still
    /// the wrong question.
    #[cfg(windows)]
    #[test]
    fn the_real_process_table_answers_both_questions() {
        let me = std::process::id();
        let parent = parent_of(me).expect("a running process has a parent");
        assert_ne!(parent, 1, "the test process must not look orphaned");
        assert_eq!(
            process_exists(me),
            Some(true),
            "this process is running"
        );
        assert_eq!(
            process_exists(parent),
            Some(true),
            "and its parent is too, or the rule above would have killed us"
        );
        let command_line = command_line_of(me).expect("a running process has a command line");
        // The real assertion: the string has to be this process's own, because
        // the module's whole identity check is a substring match against it. A
        // non-empty check would pass on a structure read from the wrong offsets.
        assert!(
            command_line.contains("dsh_shell_core") || command_line.contains("dsh-shell"),
            "the command line read back does not describe this process: {command_line}"
        );
    }

    /// A PID that cannot be running. If `process_exists` answered "yes" for a
    /// number it has never heard of, every orphan check would fail closed and the
    /// reclaim would never happen — silently, again.
    #[cfg(windows)]
    #[test]
    fn a_pid_that_cannot_exist_is_reported_as_absent() {
        assert_eq!(process_exists(0), None, "pid 0 is never a process");
    }
}
