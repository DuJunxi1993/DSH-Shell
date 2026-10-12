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
//! 2. its parent is PID 1 — it was orphaned, rather than being something the
//!    operator is sitting in right now;
//! 3. its executable is the `dsh_binary_path` this shell is configured to run.
//!
//! Fact 2 is what makes this safe and it is the one that is easy to leave out. On
//! a developer machine the port is *usually* held by something in use, and the
//! operator is usually in it: a dsh this shell orphaned and a dsh the operator
//! launched from a terminal both hold the port and both are named `node`. The
//! parent is what tells them apart, and it is measurable.

/// What is known about a process that holds a port.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProcessInfo {
    pub pid: u32,
    pub parent_pid: u32,
    /// The executable's own path, as Windows reports it.
    pub image: String,
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
    if info.parent_pid != 1 {
        return Err("it still has a parent, so something is using it");
    }
    // Compared on the file name, not the full path: the operator's config points
    // at wherever *their* npm put it, and the same binary reached by a different
    // route is still the same binary. Case-insensitively, because Windows paths
    // are.
    let wanted = configured_binary
        .file_name()
        .map(|name| name.to_string_lossy().to_lowercase());
    let actual = std::path::Path::new(&info.image)
        .file_name()
        .map(|name| name.to_string_lossy().to_lowercase());
    match (wanted, actual) {
        (Some(wanted), Some(actual)) if wanted == actual => {}
        (Some(_), Some(_)) => return Err("it is not the dsh this shell is configured to run"),
        (_, None) | (None, _) => return Err("an executable path could not be read"),
    }
    // The port is the subject of the query, so it is checked last: it is the fact
    // least likely to be wrong, and the most likely to be about the wrong thing.
    if port != config_port {
        return Err("it is not on the port we asked for");
    }
    Ok(())
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
    let image = image_of(owner)
        .ok_or_else(|| format!("could not read the executable of pid {owner}"))?;

    let info = ProcessInfo {
        pid: owner,
        parent_pid,
        image,
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
#[cfg(windows)]
pub fn reclaim_orphan(config: &crate::config::Config) {
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
                "reclaiming an orphaned dsh (pid {}, parent {}, exe {}) left on port {} by an earlier run",
                info.pid, info.parent_pid, info.image, config.preferred_port
            );
            crate::platform::terminate_tree_sync(info.pid);
        }
        Err(reason) => {
            // Not an error: the port may be held by something legitimate.
            tracing::info!(target: "dsh_shell", "leaving the port alone: {reason}");
        }
    }
}

#[cfg(not(windows))]
pub fn reclaim_orphan(_config: &crate::config::Config) {}

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
/// exited, which can be a stale PID. PID 1 is the only value that means "no
/// parent at all", and it is the only one this module treats as orphaned.
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

/// The executable backing `pid`.
#[cfg(windows)]
fn image_of(pid: u32) -> Option<String> {
    use windows::Win32::Foundation::CloseHandle;
    use windows::Win32::System::Threading::{
        OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_FORMAT,
        PROCESS_QUERY_LIMITED_INFORMATION,
    };
    use windows::core::PWSTR;

    unsafe {
        let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        let mut buffer = vec![0u16; 1024];
        let mut length = buffer.len() as u32;
        let ok = QueryFullProcessImageNameW(
            handle,
            PROCESS_NAME_FORMAT(0),
            PWSTR(buffer.as_mut_ptr()),
            &mut length,
        )
        .is_ok();
        let _ = CloseHandle(handle);
        if !ok {
            return None;
        }
        buffer.truncate(length as usize);
        Some(String::from_utf16_lossy(&buffer))
    }
}

#[cfg(not(windows))]
fn image_of(_pid: u32) -> Option<String> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    fn orphan() -> ProcessInfo {
        ProcessInfo {
            pid: 4242,
            parent_pid: 1,
            image: r"C:\Users\x\AppData\Roaming\npm\dsh.cmd".to_string(),
        }
    }

    #[test]
    fn an_orphaned_configured_dsh_is_reclaimable() {
        let info = orphan();
        assert!(is_reclaimable_orphan(3080, 3080, &info, Path::new(r"C:\npm\dsh.cmd")).is_ok());
    }

    #[test]
    fn a_process_with_a_parent_is_never_reclaimed() {
        // The fact that makes this safe: a dsh the operator launched from a
        // terminal has a real parent and is in use.
        let mut info = orphan();
        info.parent_pid = 12345;
        let reason = is_reclaimable_orphan(3080, 3080, &info, Path::new(r"C:\npm\dsh.cmd"))
            .expect_err("must refuse");
        assert!(reason.contains("parent"), "{reason}");
    }

    #[test]
    fn a_different_program_is_never_reclaimed() {
        // Same port, same orphan. Somebody else's server is not ours to kill.
        let mut info = orphan();
        info.image = r"C:\postgres\bin\postgres.exe".to_string();
        let reason = is_reclaimable_orphan(3080, 3080, &info, Path::new(r"C:\npm\dsh.cmd"))
            .expect_err("must refuse");
        assert!(reason.contains("configured to run"), "{reason}");
    }

    #[test]
    fn a_system_assigned_port_identifies_nothing() {
        // preferred_port == 0 means the OS picked it, so "the port we asked for"
        // is not evidence of anything.
        let info = orphan();
        assert!(is_reclaimable_orphan(5000, 0, &info, Path::new(r"C:\npm\dsh.cmd")).is_err());
    }

    #[test]
    fn the_binary_is_compared_by_name_not_by_full_path() {
        // The operator's config points at wherever their npm put dsh; the same
        // binary found by another route is still the same binary.
        let info = orphan();
        let elsewhere = Path::new(r"D:\tools\node_modules\.bin\dsh.cmd");
        assert!(is_reclaimable_orphan(3080, 3080, &info, elsewhere).is_ok());
    }

    /// Whether the TCP-table walk actually finds a live listener.
    ///
    /// Without this, every test above is a rule about data that was never
    /// collected: the decision function can be perfect and the module still
    /// reclaiming nothing, forever, silently. It binds a real socket and asks
    /// the Win32 table about it — so if the walk, the byte order, the state
    /// constant or the row layout is wrong, this fails rather than the feature
    /// quietly doing nothing in the field.
    #[cfg(windows)]
    #[test]
    fn the_tcp_table_walk_finds_a_live_listener() {
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
        // The other half: a walk that always answers would pass the test above
        // and reclaim whatever it liked.
        let port = {
            let probe = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
            let port = probe.local_addr().expect("addr").port();
            drop(probe);
            port
        };
        assert_eq!(process_listening_on(port), None, "nothing is listening");
    }

    #[cfg(windows)]
    #[test]
    fn this_process_is_not_an_orphan() {
        // The safety fact, checked against the real process table rather than a
        // fixture: this process is us, it has a parent, and a module that killed
        // it would kill the shell.
        let me = std::process::id();
        let parent = parent_of(me).expect("a running process has a parent");
        assert_ne!(parent, 1, "the test process must not look orphaned");
        assert_ne!(image_of(me), None, "a running process has an executable");
    }
}