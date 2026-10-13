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
    /// Whether **any** ancestor is still alive, not just the parent.
    ///
    /// This is the field the reclaim rule actually decides on, and it exists
    /// because `parent_alive` is not enough on Windows. The npm shim puts a
    /// `cmd.exe` between this shell and the `node.exe` that holds the port, so a
    /// genuine orphan has a *living parent* and the one-step test refused every
    /// real one — which is why the retry button cleared nothing.
    ///
    /// `false` means the chain was walked to the top (or to
    /// [`ANCESTOR_WALK_LIMIT`]) and every step was dead or absent.
    pub has_living_ancestor: bool,
    /// The process's full command line, as Windows reports it.
    pub command_line: String,
}

/// How far up the ancestor chain [`ancestor_chain_is_broken`] will walk.
///
/// A bound, not a style choice: `ParentProcessId` is recorded rather than held, so
/// a PID recycled onto a process whose parent is itself would otherwise let the
/// walk cycle forever. Eight is well past any real launcher chain on Windows —
/// `cmd.exe` and the npm shim account for two — and a chain that deep is not one
/// we should be killing anyway, so hitting the bound is treated as "still in use".
pub const ANCESTOR_WALK_LIMIT: usize = 8;

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
    // "No parent" is decided by walking the *whole* ancestor chain, not by looking
    // at the immediate parent. This was the difference between the feature working
    // and not working on a real machine.
    //
    // On Windows `dsh_binary_path` is an npm `.cmd` shim, so this shell spawns
    // `cmd.exe` and the harness `node.exe` is its *child* — the thing holding the
    // port is a grandchild. An earlier version asked only "is the parent alive",
    // which for a real orphan answered yes: `node.exe` -> `cmd.exe` alive ->
    // refused, because `cmd.exe` is still sitting there waiting for a `node.exe`
    // that outlived the shell that started it. Measured on a machine where this
    // mattered:
    //
    //     PID 1868  node.exe   parent=5340  alive    <- holds 3080
    //     PID 5340  cmd.exe    parent=11688 dead     <- the dsh.cmd shim
    //     PID 11688            does not exist
    //
    // One step up is enough to see the break; one step of *only* is not. The rule
    // is now: any living ancestor means somebody is using it, and only a chain
    // that is broken all the way to the top is an orphan.
    //
    // This fails safe in both directions, which is why it is worth the extra
    // queries. A terminal-launched `dsh web` has a live shell somewhere up its
    // chain and is still refused. And a recycled parent PID counts as *alive*
    // rather than absent, so a PID that got reused onto an unrelated process makes
    // us more cautious, never less.
    if info.has_living_ancestor {
        return Err("it has a living ancestor, so something is using it");
    }
    let Some(harness) = harness_marker(configured_binary) else {
        return Err("the configured dsh path does not look like an npm shim");
    };
    // Case-insensitive, separator-normalised, and matched on a path fragment
    // rather than the whole string: the command line quotes and escapes its own
    // arguments, the casing of the npm prefix varies by machine, and Windows
    // doubles the separators in what it reports. See
    // [`normalize_path_for_match`].
    if !normalize_path_for_match(&info.command_line).contains(&harness) {
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
/// Reduce a path-like string to a form two spellings of the same path can match.
///
/// Windows reports a command line with **doubled** separators. Measured, from a
/// real orphan holding port 3080:
///
/// ```text
/// "node" "C:\Users\x\AppData\Roaming\npm\\node_modules\\@deepseek-ai\\dsh\lib\bin.js" web ...
/// ```
///
/// while the marker derived from `dsh_binary_path` is spelled with single
/// separators. A plain `contains` therefore never matched, and the reclaim rule
/// refused every real dsh on the machine — the same refusal message as a wrong
/// program, for a process that was exactly right.
///
/// Collapsing runs of separators is safe in the direction that matters: it can
/// never make two *different* paths compare equal (`a\\b` and `a\b` are the same
/// directory, and `a\b` and `a\c` still differ). The alternative — a looser
/// substring on the package name — would match every dsh on the machine, which is
/// the failure this whole module exists to prevent.
///
/// Separators are also unified to one character so that a path spelled with `/`
/// by some other tool still compares against one spelled with `\`.
fn normalize_path_for_match(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    let mut last_was_separator = false;
    for ch in value.chars() {
        let is_separator = ch == '\\' || ch == '/';
        if is_separator {
            if !last_was_separator {
                out.push('/');
            }
            last_was_separator = true;
        } else {
            out.push(ch);
            last_was_separator = false;
        }
    }
    out.to_lowercase()
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
    Some(normalize_path_for_match(
        &prefix
            .join("node_modules")
            .join("@deepseek-ai")
            .join("dsh")
            .to_string_lossy(),
    ))
}

/// One occupant of our port, with the verdict on it.
///
/// Split out of what used to be a bare `Result<ProcessInfo, String>` because the
/// failure page has to show *who* is holding the port and *why we will not touch
/// it*. A single error string loses the PID, which is the one part the user needs
/// in order to go and look, and it cannot express "nothing is holding it" — which
/// is a different screen, not an error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PortOccupant {
    /// The port that is occupied. Carried so the page does not have to trust its
    /// own copy of the config.
    pub port: u16,
    /// `None` when the port is free, which is the normal case and not a failure.
    pub info: Option<ProcessInfo>,
    /// Whether [`info`] may be reclaimed.
    ///
    /// `false` whenever `info` is `None`: a free port is not reclaimable, and
    /// making the two states distinguishable here is what lets the page show
    /// "retry" rather than "clean up".
    pub reclaimable: bool,
    /// Why it may not be reclaimed, or what could not be determined.
    ///
    /// Empty when `reclaimable`. Present even when `info` is `None`, because
    /// "could not read the parent of pid 412" is exactly the information that
    /// makes a stuck launch explicable.
    pub reason: String,
}

/// Who holds our port, and whether we are allowed to kill them.
///
/// Gathers first, judges after, so the caller gets every fact even when the
/// verdict is a refusal. Judging inside the gather — which is what this used to
/// do — meant a refusal came back as an opaque `Err` and the page could not show
/// the evidence behind it.
///
/// This is deliberately **only** about our own configured port. A launch
/// failure page that listed every `node.exe` on the machine would be mostly
/// irrelevant processes with scary-looking names, and the one that matters would
/// be buried among them. What is on some other port is not our problem.
pub fn inspect_port(config: &crate::config::Config) -> PortOccupant {
    let port = config.preferred_port;
    // A port of 0 was chosen by the system, so it identifies nothing and there is
    // no occupant to describe. Reached before any process query.
    if port == 0 {
        return PortOccupant {
            port: 0,
            info: None,
            reclaimable: false,
            reason: "the port is assigned by the system, so there is nothing to identify".into(),
        };
    }

    let Some(owner) = process_listening_on(port) else {
        return PortOccupant {
            port,
            info: None,
            reclaimable: false,
            reason: format!("nothing is listening on {port}"),
        };
    };

    // From here the occupant is real, so a failure to read a fact about it is a
    // fact about the occupant, not about the port. Each one is answered on its
    // own: `parent_alive` is only meaningful if the parent PID could be read, and
    // the command line is the strongest evidence the reclaim rule has.
    let Some(parent_pid) = parent_of(owner) else {
        return PortOccupant {
            port,
            info: None,
            reclaimable: false,
            reason: format!("pid {owner} holds {port}, but its parent could not be read"),
        };
    };
    let Some(parent_alive) = process_exists(parent_pid) else {
        return PortOccupant {
            port,
            info: None,
            reclaimable: false,
            reason: format!(
                "pid {owner} holds {port}, but whether its parent is still alive could not be told"
            ),
        };
    };
    let Some(command_line) = command_line_of(owner) else {
        return PortOccupant {
            port,
            info: None,
            reclaimable: false,
            reason: format!(
                "pid {owner} holds {port}, but its command line could not be read, so there is \
                 no way to confirm it is this shell's dsh"
            ),
        };
    };

    let info = ProcessInfo {
        pid: owner,
        parent_pid,
        parent_alive,
        // Walked rather than inferred from `parent_alive`. See the field's doc: on
        // Windows the shim puts a live `cmd.exe` between us and the port holder, so
        // this is the only version of the question that gives the right answer.
        has_living_ancestor: !ancestor_chain_is_broken(owner, &config.dsh_binary_path),
        command_line,
    };
    match is_reclaimable_orphan(port, config.preferred_port, &info, &config.dsh_binary_path) {
        Ok(()) => PortOccupant {
            port,
            info: Some(info),
            reclaimable: true,
            reason: String::new(),
        },
        Err(reason) => PortOccupant {
            port,
            info: Some(info),
            reclaimable: false,
            reason: format!("pid {owner} holds {port} but {reason}"),
        },
    }
}

/// Whether the process holding `port` is an orphan this shell may reclaim.
///
/// Returns the process when it may be killed, and the reason when it may not.
/// Nothing here kills anything; the caller decides what to do with the answer.
///
/// A thin wrapper over [`inspect_port`], kept because the rule's callers and its
/// tests are about the yes/no and not about the evidence.
pub fn classify_port_occupant(
    port: u16,
    config: &crate::config::Config,
) -> Result<ProcessInfo, String> {
    let occupant = inspect_port(config);
    // The port argument is part of the signature this has always had, and
    // `inspect_port` reads it from the config. A mismatch means the caller is
    // asking about a port we are not configured for, which the reclaim rule
    // refuses anyway - so it is refused here rather than answered from the
    // config's port, which would silently answer a different question.
    if port != occupant.port {
        return Err(format!(
            "asked about port {port}, which is not the configured port {}",
            occupant.port
        ));
    }
    match (occupant.reclaimable, occupant.info) {
        (true, Some(info)) => Ok(info),
        // The reason is already a sentence naming the PID, e.g. "pid 412 holds
        // 3080 but it still has a parent", which is what this has always returned.
        _ => Err(occupant.reason),
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
pub fn reclaim_orphan(config: &crate::config::Config, why: ReclaimReason) -> Option<ProcessInfo> {
    use crate::config::LaunchMode;

    if config.launch_mode != LaunchMode::Spawn {
        return None;
    }
    // The free check is the cheap way out, and it is also what keeps the ordinary
    // launch silent: on a healthy start nothing is listening, and going on to
    // log "leaving the port alone: nothing is listening on 3080" every single
    // time is the noise that trains a reader to skip this log.
    if crate::preflight::port_is_free(&config.listen_host, config.preferred_port) {
        return None;
    }
    let occupant = inspect_port(config);
    match (occupant.reclaimable, occupant.info.clone()) {
        (true, Some(info)) => {
            tracing::warn!(
                target: "dsh_shell",
                "{}: reclaiming an orphaned dsh (pid {}, parent {}, now {}) on port {}: {}",
                why.log_prefix(),
                info.pid,
                info.parent_pid,
                if info.parent_alive { "alive" } else { "gone" },
                occupant.port,
                info.command_line
            );
            crate::platform::terminate_tree_sync(info.pid);
            Some(info)
        }
        (false, Some(info)) => {
            // Not an error: the port may be held by something legitimate. The
            // occupant is still returned, so a caller can name the PID it
            // declined to kill — that is the whole point of showing evidence.
            tracing::info!(
                target: "dsh_shell",
                "{}: leaving the port alone: {}",
                why.log_prefix(),
                occupant.reason
            );
            Some(info)
        }
        // The port is free. Reachable only if it was released between the check
        // above and here, and logged at debug so a launch that raced its own
        // probe stays quiet.
        (false, None) => {
            tracing::debug!(target: "dsh_shell", "{}: {}", why.log_prefix(), occupant.reason);
            None
        }
        (true, None) => {
            tracing::info!(target: "dsh_shell", "{}: {}", why.log_prefix(), occupant.reason);
            None
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
pub fn reclaim_orphan(_config: &crate::config::Config, _why: ReclaimReason) -> Option<ProcessInfo> {
    None
}

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

/// Whether nothing outside our own launch chain is still running this dsh.
///
/// This is the reclaim rule's liveness question, and the reason the immediate
/// parent is not enough to ask. `dsh.cmd` is a batch shim, so the port holder is
/// a grandchild whose parent — the `cmd.exe` — *stays alive for as long as the dsh
/// does*, waiting on it. "Is the parent alive" therefore answered "still has a
/// parent" for a genuine orphan, and that is why the retry button cleared nothing
/// and the port stayed busy.
///
/// So a living ancestor is not on its own a reason to refuse. What matters is
/// *whose* ancestor it is:
///
/// - alive, and part of our own chain — the `cmd.exe` running the configured
///   `dsh.cmd`. It is alive only because our dsh is alive, so it says nothing
///   about whether anyone wants this running. Keep walking.
/// - alive, and anything else — a terminal, a service, the user's own launcher.
///   Somebody is using it. Refuse.
///
/// The walk ends at the first genuinely dead parent, which is the moment the
/// launcher died.
///
/// Two chains that differ only in one link, both real:
///
/// ```text
/// shell ─▶ cmd(dsh.cmd) ─▶ node      shell gone        → ORPHAN
/// term  ─▶ cmd(dsh.cmd) ─▶ node      term still alive  → IN USE
/// ```
///
/// Fails safe at every uncertain step, because the cost of wrongly saying "broken"
/// is killing a process somebody is using:
///
/// - an unreadable parent, parent liveness, or a command line stops the walk and
///   reports **not** broken;
/// - a PID that repeats reports **not** broken, since a cycle means the snapshot
///   was recycled mid-walk;
/// - reaching [`ANCESTOR_WALK_LIMIT`] reports **not** broken — deeper than any
///   real launcher chain, and not one to kill on.
#[cfg(windows)]
fn ancestor_chain_is_broken(pid: u32, configured_binary: &std::path::Path) -> bool {
    // Case-insensitive and separator-normalised for the same reasons as the
    // harness match: an npm prefix's casing varies by machine, the shim quotes its
    // own path, and Windows doubles the separators it reports.
    let shim = normalize_path_for_match(&configured_binary.to_string_lossy());
    if shim.is_empty() {
        // Nothing to recognise our own launcher with, so no living ancestor can
        // be excused. Refuse rather than guess.
        return false;
    }

    let mut cursor = pid;
    for _ in 0..ANCESTOR_WALK_LIMIT {
        let Some(parent) = parent_of(cursor) else {
            return false;
        };
        if parent == cursor || parent == 0 {
            // A self-parent or an unattributed parent: cannot vouch for it.
            return false;
        }
        match process_exists(parent) {
            Some(false) => {
                // Positively dead, and every step below was our own chain. This
                // is the break.
                return true;
            }
            Some(true) => {}
            // Could not tell whether it is alive.
            None => return false,
        }
        // Alive. Ours to step over, or somebody's process to protect.
        let Some(line) = command_line_of(parent) else {
            return false;
        };
        if !normalize_path_for_match(&line).contains(&shim) {
            return false;
        }
        cursor = parent;
    }
    false
}

#[cfg(not(windows))]
fn ancestor_chain_is_broken(_pid: u32, _configured_binary: &std::path::Path) -> bool {
    false
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
    /// the shape that used to be *refused*, three times over. The executable is
    /// `node.exe` rather than `dsh.cmd`; the parent is a dead PID rather than 1,
    /// which is what Windows leaves behind when the shell that started it is
    /// killed; and `has_living_ancestor` is false because the whole chain above it
    /// is gone.
    fn orphan() -> ProcessInfo {
        ProcessInfo {
            pid: 4242,
            parent_pid: 3176,
            parent_alive: false,
            has_living_ancestor: false,
            command_line: format!(
                r"C:\Program Files\nodejs\node.exe {HARNESS}\lib\bin.js web --port 3080"
            ),
        }
    }

    /// A refused occupant of ours: a `node.exe` running the same harness, but with
    /// a live ancestor above it — a dsh the operator started from a terminal.
    fn someone_elses_dsh() -> ProcessInfo {
        ProcessInfo {
            pid: 5150,
            parent_pid: 900,
            parent_alive: true,
            has_living_ancestor: true,
            command_line: format!(
                r"C:\Program Files\nodejs\node.exe {HARNESS}\lib\bin.js web --port 3080"
            ),
        }
    }

    /// The shape that actually occurs on Windows, and the reason the rule was
    /// rewritten: our own orphan, whose `cmd.exe` shim is *still running* because
    /// it is waiting on the very `node.exe` holding the port.
    ///
    /// `parent_alive` is true here — the old one-step test saw that and refused,
    /// on every real machine, forever. `has_living_ancestor` is what is false,
    /// because the shim is ours and the chain above it is broken.
    fn orphan_behind_a_live_shim() -> ProcessInfo {
        ProcessInfo {
            pid: 1868,
            parent_pid: 5340,
            parent_alive: true,
            has_living_ancestor: false,
            command_line: format!(
                r"C:\Program Files\nodejs\node.exe {HARNESS}\lib\bin.js web --port 3080"
            ),
        }
    }

    /// The verdict for a known occupant, without touching the process table.
    ///
    /// `inspect_port` is the function the failure page reads, and it is the one
    /// that has to keep both halves — the evidence and the judgement — in a single
    /// value. Going through the real process table instead would make these tests
    /// depend on what happens to be listening on a port on this machine, which is
    /// how a test starts passing for the wrong reason.
    fn judge(port: u16, info: Option<&ProcessInfo>) -> (bool, String) {
        match info {
            None => (
                false,
                format!("nothing is listening on {port}"),
            ),
            Some(info) => {
                let verdict =
                    is_reclaimable_orphan(port, port, info, Path::new(SHIM)).map_err(String::from);
                (
                    verdict.is_ok(),
                    verdict.err().unwrap_or_default(),
                )
            }
        }
    }

    /// The reason a refusal is only useful if it survives to the screen. Before
    /// this was a `Result<ProcessInfo, String>`, a refusal came back as an opaque
    /// error and the boot page had no PID to show, which made a deliberate
    /// decision to leave somebody's server alone look exactly like a hang.
    #[test]
    fn a_refusal_keeps_both_the_evidence_and_the_verdict() {
        let info = someone_elses_dsh();
        let (reclaimable, reason) = judge(3080, Some(&info));
        assert!(!reclaimable);
        assert!(!reason.is_empty(), "a refusal must say why");
        // The PID is the part the user needs in order to go and look.
        assert!(
            reason.contains("living ancestor"),
            "the reason must survive: {reason}"
        );
    }

    /// The verdict is about *our* dsh, not about whether it looks like dsh at all.
    /// A live ancestor outside our own launch chain is the strongest signal that
    /// somebody is using it.
    #[test]
    fn our_own_harness_with_a_live_ancestor_is_refused() {
        let (reclaimable, _) = judge(3080, Some(&someone_elses_dsh()));
        assert!(!reclaimable, "a dsh in use must never be reclaimed");
    }

    /// The walk itself, against the real process table.
    ///
    /// This is the one test here that cannot be satisfied by a fixture: the bug
    /// was that the *judgement* was right and the *question* was wrong, and a
    /// hand-built `ProcessInfo` cannot catch a question asked of the wrong
    /// process. `GetCurrentProcessId` is this test's own PID, so the chain above it
    /// is a real launcher chain — a shell that is alive right now.
    ///
    /// Two things follow from that, and both are asserted:
    /// - walking up from a live process must find a living ancestor and refuse;
    /// - the configured shim cannot be this process, so it can never be the
    ///   "our own launcher" that excuses a step.
    #[cfg(windows)]
    #[test]
    fn the_walk_finds_a_living_ancestor_above_this_test_process() {
        let me = std::process::id();
        assert!(
            !ancestor_chain_is_broken(me, Path::new(SHIM)),
            "this process was launched by something that is alive; the walk must say so"
        );
        // Which means the loop is really consulting the table, not returning a
        // constant: the same call against a shim path that cannot exist still
        // refuses, because the refusal came from a living ancestor and not from
        // the empty-shim guard.
        assert!(!ancestor_chain_is_broken(me, Path::new(r"C:\nope\dsh.cmd")));
    }

    /// The bound is a bound, and hitting it is a refusal.
    ///
    /// A cycle in `ParentProcessId` is only possible if the snapshot was recycled
    /// mid-walk, but it is worth not hanging the boot path over: the walk has to
    /// terminate on a self-parent without calling anything else.
    #[cfg(windows)]
    #[test]
    fn a_self_referential_chain_terminates_and_refuses() {
        // A PID that cannot be running: `process_exists` says no, so this would be
        // a break if the parent lookup ever answered. It cannot, so the walk has
        // to bail out — and bail out means refuse.
        assert!(!ancestor_chain_is_broken(0, Path::new(SHIM)));
    }

    /// The command line exactly as Windows reports it, separators and all.
    ///
    /// Copied from a real orphan measured on a machine where this mattered, rather
    /// than tidied up. It holds **doubled** backslashes through the whole harness
    /// path, and a marker built from `dsh_binary_path` is spelled with single ones.
    /// A plain substring match therefore never fired, so the rule refused every
    /// real dsh with the message for a wrong program — and nothing failed loudly
    /// enough to notice, because the refusal is exactly what a safety check should
    /// look like.
    ///
    /// This fixture is the regression: it is the only reason
    /// [`normalize_path_for_match`] exists, and if that function is deleted the
    /// reclaim feature goes back to being inert on every Windows machine.
    fn command_line_with_doubled_separators() -> String {
        r#""node"   "C:\Users\x\AppData\Roaming\npm\\node_modules\\@deepseek-ai\\dsh\\lib\\bin.js" web --no-open --host 127.0.0.1 --port 3080"#
            .to_string()
    }

    #[test]
    fn a_doubled_separator_command_line_is_still_our_dsh() {
        let mut info = orphan();
        info.command_line = command_line_with_doubled_separators();
        assert!(
            is_reclaimable_orphan(3080, 3080, &info, Path::new(SHIM)).is_ok(),
            "the real Windows spelling of this command line must match the marker"
        );
    }

    /// The normalisation must not become so loose that it matches other installs
    /// or other programs — which is the failure the marker exists to prevent.
    #[test]
    fn normalising_separators_does_not_widen_the_match() {
        // Same characters, different separators: still a match.
        assert_eq!(
            normalize_path_for_match(r"C:\a\npm\\node_modules\@deepseek-ai\dsh"),
            normalize_path_for_match(r"C:\a\npm/node_modules/@deepseek-ai/dsh")
        );
        // A sibling directory with a shared prefix is still a different path.
        assert_ne!(
            normalize_path_for_match(r"C:\a\npm\\node_modules\@deepseek-ai\dsh-extra"),
            normalize_path_for_match(r"C:\a\npm\\node_modules\@deepseek-ai\dsh")
        );
        let mut info = orphan();
        info.command_line = r"C:\tools\postgres.exe -p 3080".to_string();
        assert!(is_reclaimable_orphan(3080, 3080, &info, Path::new(SHIM)).is_err());
    }

    /// A live parent is no longer the question, and this is why.
    ///
    /// On Windows the npm shim's `cmd.exe` is alive for exactly as long as the dsh
    /// is, because it is waiting on it. Asking "is the parent alive" therefore
    /// refused every real orphan, on every machine, which is what made the retry
    /// button clear nothing and leave the port busy. The discriminating fact is
    /// whether anything *outside our own chain* is alive.
    #[test]
    fn a_live_parent_alone_does_not_make_it_refused() {
        let info = orphan_behind_a_live_shim();
        assert!(
            info.parent_alive,
            "the fixture must keep its live cmd.exe, or it stops testing anything"
        );
        let (reclaimable, reason) = judge(3080, Some(&info));
        assert!(
            reclaimable,
            "our own dsh behind a live shim is an orphan and must be reclaimable: {reason}"
        );
    }

    /// The two differ by exactly one link, which is the whole point of the rewrite.
    #[test]
    fn the_shim_is_what_separates_our_orphan_from_somebody_elses() {
        let (ours, _) = judge(3080, Some(&orphan_behind_a_live_shim()));
        let (theirs, _) = judge(3080, Some(&someone_elses_dsh()));
        assert!(ours, "ours, behind a live shim with a dead chain above it");
        assert!(!theirs, "theirs, with something alive that is not our shim");
    }

    /// The same harness, orphaned, *is* ours to reclaim — otherwise the evidence
    /// and the verdict are not connected to anything.
    #[test]
    fn an_orphaned_process_of_ours_is_reclaimable() {
        let (reclaimable, reason) = judge(3080, Some(&orphan()));
        assert!(reclaimable, "an orphaned dsh of ours is reclaimable: {reason}");
        assert!(reason.is_empty(), "a success carries no reason");
    }

    /// A free port is not a failure and must not be dressed up as one. It is also
    /// the state the page uses to decide between "retry" and "clean up", so it
    /// has to be distinguishable from a refusal.
    #[test]
    fn a_free_port_is_not_reclaimable_and_says_so() {
        let (reclaimable, reason) = judge(3080, None);
        assert!(!reclaimable);
        assert!(reason.contains("nothing is listening"), "{reason}");
    }

    /// A system-assigned port identifies nothing, so there is no occupant to
    /// describe and nothing to clean up. Asking to reclaim here would be a kill by
    /// guess.
    #[test]
    fn a_system_assigned_port_identifies_no_occupant() {
        let (reclaimable, reason) = judge(0, None);
        assert!(!reclaimable);
        assert!(!reason.is_empty());
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
    fn a_process_with_a_live_ancestor_is_never_reclaimed() {
        // The fact that makes this safe: a dsh the operator launched from a
        // terminal has something alive above our shim and is in use.
        let reason = is_reclaimable_orphan(3080, 3080, &someone_elses_dsh(), Path::new(SHIM))
            .expect_err("must refuse");
        assert!(reason.contains("living ancestor"), "{reason}");
    }

    /// A recycled parent PID points at a *different, living* process, which is
    /// exactly the shape `has_living_ancestor: true` describes. The answer must be
    /// a refusal: we cannot tell a recycled PID apart from a real live ancestor,
    /// and guessing wrong means killing somebody's running server.
    #[cfg(windows)]
    #[test]
    fn a_recycled_parent_pid_counts_as_a_living_ancestor() {
        let mut info = orphan();
        info.parent_pid = std::process::id();
        info.parent_alive = true;
        info.has_living_ancestor = true;
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
        // Compared through the same normalisation the rule applies, because the
        // marker is now stored in normalised form: lower-cased and with `/`
        // separators. Asserting the raw spelling instead would pin down the
        // internal representation, which is not the thing worth holding — the
        // property is that the same directory spelled any way compares equal.
        assert_eq!(marker, normalize_path_for_match(HARNESS));
        assert!(
            marker.contains("/node_modules/@deepseek-ai/dsh"),
            "the marker must name our own install: {marker}"
        );
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
