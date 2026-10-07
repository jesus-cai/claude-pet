import AppKit
import Darwin

/// What Claude is doing right now, as reported by the hook script (or guessed from
/// CPU when nobody reports). The pet says one line per state, so the list is short
/// on purpose: more states than this and the balloon turns into a log.
enum ClaudeState: String {
    case idle, thinking, reading, writing, running, searching, delegating, waiting, done
    /// The answer was cut short - Esc, Ctrl+C - rather than finished. It ends the
    /// stretch like `done` does, but there is nothing to celebrate.
    case stopped
    /// The turn ended on an API error (overloaded, usage limit...). Not an answer:
    /// she tells you in red instead of celebrating.
    case error

    /// States where an answer is actually being produced. `waiting` is not one of
    /// them - she is blocked on you, not working - and neither is `done`.
    var isWorking: Bool {
        switch self {
        case .thinking, .reading, .writing, .running, .searching, .delegating: return true
        case .idle, .waiting, .done, .stopped, .error: return false
        }
    }
}

/// Something that happened in one Claude Code session, edge-triggered: it is noticed
/// whenever the pet next looks, however late that is. The level-triggered `state`
/// only says what is going on *now*, and a `done` that came and went while the
/// screen slept (the display link pauses, so nobody polls) used to vanish without a
/// trace - the single most common "no avisó".
struct ClaudeEvent {
    enum Kind {
        case finished        // a turn ended with an answer
        case failed          // a turn ended on an API error
        case needsYou        // a permission prompt / question went up
        case engaged         // the session is working again, or you cut it short
        case gone            // the session ended
    }
    let kind: Kind
    let session: String
    let project: String
    let detail: String
    /// Found already standing at launch: show it, but don't ring.
    let quiet: Bool
}

/// Watches the Claude desktop app: is it open, is it in front, and is it busy?
/// "Busy" is inferred from the CPU the Claude process tree burns, compared with
/// its own recent floor, so it adapts instead of using a fixed number.
///
/// The expensive half - walking every pid on the machine, reading per-process CPU,
/// asking the window server for geometry - runs on a background queue and publishes
/// a snapshot. On the main thread it was a syscall storm landing in the middle of an
/// animation frame every 1.5 s, which is exactly what a periodic hitch looks like.
final class ClaudeProbe {
    static let bundleID = "com.anthropic.claudefordesktop"

    private(set) var isRunning = false      // main thread only
    private(set) var isFrontmost = false    // main thread only

    /// What she reacts to. Composed on `poll`, main thread only.
    private(set) var state: ClaudeState = .idle
    /// The concrete thing: a file name, a command, a query. May be empty.
    private(set) var detail = ""
    /// True when a hook told us, false when we are guessing from CPU. The guess is
    /// noisy, so some of her reactions are only allowed when this is true.
    private(set) var isSignalled = false
    /// Folder name of the session being shown, empty when unknown or guessed.
    private(set) var project = ""

    /// One live Claude Code session, as its file says right now.
    struct SessionInfo {
        let key: String
        let project: String
        let state: ClaudeState
        /// Seconds since the file changed (or since a settled state took effect).
        let age: TimeInterval
        let detail: String
        let at: Date
    }
    /// Every live session, most recently active first.
    private(set) var sessions: [SessionInfo] = []

    /// Events since the last `takeEvents`, oldest first.
    private var events: [ClaudeEvent] = []
    func takeEvents() -> [ClaudeEvent] { defer { events.removeAll() }; return events }

    /// The same events, numbered, for many listeners at once (one pet per session):
    /// each feed keeps its own cursor, so none takes an event from another.
    /// `takeEvents` stays the queue of the combined pet, as always.
    private(set) var log: [(seq: Int, event: ClaudeEvent)] = []
    private(set) var seq = 0
    private func emit(_ e: ClaudeEvent) {
        events.append(e)
        seq += 1
        log.append((seq, e))
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }
    // ---- sessions taken off by hand ----
    //
    // Right-click → "Quitar esta sesión": no line in the menu, no pet, no notice, until
    // it gets back to work. `open` means the turn that was running when you took it off
    // has not ended yet: whatever it does until then does not bring it back. What does:
    // work (or a prompt) after that turn ended, or a new message of yours (an Esc leaves
    // no Stop behind). Claude Desktop ("desktop") comes back when it answers again.
    struct Hidden { var open: Bool; var at: Date }
    private(set) var hidden: [String: Hidden] = [:]
    /// Called whenever `hidden` changes, so it can be saved.
    var onHiddenChange: (() -> Void)?
    func isHidden(_ key: String) -> Bool { hidden[key] != nil }
    func restoreHidden(_ h: [String: Hidden]) { hidden = h }

    func hide(_ key: String) {
        let open: Bool
        if key == "desktop" { open = snapshot.busy }
        else if let s = sessions.first(where: { $0.key == key }) { open = s.state.isWorking || s.state == .waiting }
        else { open = false }
        hidden[key] = Hidden(open: open, at: Date())
        onHiddenChange?()
    }

    func unhideAll() {
        // back as they were, not as new: one that finished a while ago is not celebrated again
        for s in Self.readSignals(presence: presence) {
            if let k = s.url?.lastPathComponent, hidden[k] != nil { seen[k] = (s.state, s.at) }
        }
        hidden = [:]
        onHiddenChange?()
    }

    /// Drops the hidden sessions from what the files say, and lets back the ones that
    /// got back to work. Hidden sessions whose file is gone are forgotten.
    private func screen(_ all: [Signal]) -> [Signal] {
        guard !hidden.isEmpty else { return all }
        var changed = false
        var out: [Signal] = []
        for s in all {
            guard let key = s.url?.lastPathComponent, var h = hidden[key] else { out.append(s); continue }
            let active = s.state.isWorking || s.state == .waiting
            if !active {
                if h.open { h.open = false; hidden[key] = h; changed = true }
                continue
            }
            // a second of slack: the file's date and the clock don't agree to the millisecond
            if !h.open || (s.source == "UserPromptSubmit" && s.at > h.at.addingTimeInterval(1)) {
                hidden[key] = nil; changed = true; out.append(s)
            }
        }
        let fm = FileManager.default
        for key in Array(hidden.keys) where key != "desktop" {
            if presence[key] == nil, !fm.fileExists(atPath: Self.sessionsDir.appendingPathComponent(key).path) {
                hidden[key] = nil; changed = true
            }
        }
        if hidden["desktop"] != nil, !desktopRunning {
            hidden["desktop"] = nil; changed = true          // closed: forgotten
        } else if var d = hidden["desktop"] {
            if !snapshot.busy {
                if d.open { d.open = false; hidden["desktop"] = d; changed = true }
            } else if !d.open { hidden["desktop"] = nil; changed = true }
        }
        if changed { onHiddenChange?() }
        return out
    }

    /// What each session file said last time we looked, by file name.
    private var seen: [String: (state: ClaudeState, at: Date)] = [:]
    private var primed = false

    var isBusy: Bool { state.isWorking }
    var cpu: Double { snapshot.cpu }
    var windowCenter: CGPoint? { snapshot.center }

    private struct Snapshot { var busy = false; var cpu: Double = 0; var center: CGPoint? }
    private let lock = NSLock()
    private var stored = Snapshot()
    private var snapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return stored }
    private func publish(_ s: Snapshot) { lock.lock(); stored = s; lock.unlock() }

    private let queue = DispatchQueue(label: "com.juli.compa.probe", qos: .utility)
    private var sampling = false            // main thread only

    // all of these belong to `queue` once sampling starts
    private var pids: [pid_t] = []
    private var pidsRefreshed: CFTimeInterval = -100
    private var lastCPUTime: Double = 0
    private var lastSample: CFTimeInterval = 0
    private var floorHistory: [Double] = []
    // not 0: the clock starts at 0 too, so she'd wake up believing Claude had just
    // been busy and would announce an answer that never happened
    private var busySince: CFTimeInterval = -100
    private var hotStreak = 0
    private var loudStreak = 0

    /// How long a burst of CPU keeps counting as "still answering" after it stops.
    ///
    /// It used to be 2,2 s, which is the right order of magnitude for the gaps between
    /// tokens and the wrong one for what a real answer looks like. Measured on a live
    /// session - 525 s of trace, Claude Desktop in front - the load comes in bursts
    /// with **gaps of four to five seconds** between them, and twice it went quiet for
    /// half a minute in the middle of the same conversation. At 2,2 s she fell out
    /// three times, which is three "done!" over one answer: she'd celebrate, go back to
    /// working, celebrate again. That is what "no lo hizo del todo bien" looked like.
    ///
    /// At 8 s the same trace is one single stretch of work and one celebration. The
    /// cost is that the desktop app's "done!" lands up to 8 s late; Claude Code doesn't
    /// pay it, because there nothing is being guessed.
    private static let busyHold: CFTimeInterval = 12
    // A task with tools (commands, searches) runs on the server: meanwhile the app barely
    // uses CPU, and with an 8 s margin she announced "done" at the first command. When
    // the load comes back after a pause there are tools in play, and from then on she
    // waits much longer before calling the task finished.
    private static let toolGap: CFTimeInterval = 8      // quiet this long, then work again = a tool ran
    // Measured on a real Mac (a 5-minute task, commands up to 1.5 min): while a tool runs
    // the app burns 1-5 % (its animation) against 0 % at rest, but one stretch stayed near
    // zero for 16 s. 30 s is almost twice that.
    private static let toolHold: CFTimeInterval = 30    // margin once tools are known to be in play
    private static let warm = 0.015                     // the app's "working" animation while a tool runs
    // ...but a long conversation open in the app burns that much at rest too: unbounded,
    // the pet stayed "thinking" forever after the answer. The small load only counts for
    // this long after the last real burst (on a real Mac, with 1.5-minute commands, there
    // was never more than 20 s without one).
    private static let warmLimit: CFTimeInterval = 25
    private var holdFor: CFTimeInterval = 12            // belongs to `queue`, like the rest of the sampling
    private var lastHotAt: CFTimeInterval = -100

    /// QA hook: pretends Claude answers for 9 s out of every 22, so the working and
    /// celebrating states can be watched without waiting on the real app.
    static let fakeBusy = ProcessInfo.processInfo.environment["COMPA_FAKEBUSY"] != nil

    /// Anything that can run a shell command can drive her through these files. Each
    /// Claude Code session writes `<state>\t<detail>` into one of them - that is how
    /// Claude Code reports in (via the hooks in `hooks/compa-hook.sh`), because there
    /// the CPU heuristic would be useless: the model burns its cycles on a server,
    /// not on this machine.
    ///
    /// One file per session and not one shared file, because two sessions at once
    /// would trample each other - the `Stop` of the one you are not looking at would
    /// take down the balloon of the one you are.
    ///
    /// `COMPA_SESSIONS` points her at another directory, for driving her from a
    /// script without the live sessions (the one you are testing from included)
    /// talking over the test.
    static let sessionsDir: URL = {
        if let p = ProcessInfo.processInfo.environment["COMPA_SESSIONS"], !p.isEmpty {
            return URL(fileURLWithPath: p)
        }
        return PetLibrary.home.appendingPathComponent("sessions")
    }()

    /// The original signal, kept working: a bare file that exists while an answer is
    /// being written. Anything older than the state files can still drive her.
    static let signalFile = PetLibrary.home.appendingPathComponent("busy")

    /// A session that crashed mid-answer would leave the file behind and freeze her in
    /// "working" forever, so a stale one is ignored - but only when there is no pid to
    /// ask. With a pid, a dead process drops the file at once and a live one keeps it
    /// for as long as it lives: a permission prompt you walk away from for an hour, or
    /// a 20-minute build, are not stale. (They used to be, after 15 minutes, and that
    /// silenced exactly the prompt you came back to answer.)
    private static let signalGoesStale: TimeInterval = 15*60

    /// How long a finished session keeps the floor. Its file stays behind until the
    /// session closes, and `done` is where a Claude Code session spends most of its
    /// life - between turns. Letting that count as "someone is reporting" is what made
    /// Claude Desktop invisible for as long as a terminal was open: the signal wins
    /// over the CPU guess by design, so a `done` sitting there all afternoon switched
    /// the desktop app off. It counts just long enough to be celebrated.
    static let doneGoesQuiet: TimeInterval = 6

    /// `waiting` used to expire on its own too, after 45 s, on the theory that nothing
    /// ever cleared it. That was wrong, and it cost the one notice she exists for:
    /// walk away from a permission prompt, come back two minutes later, and she was
    /// idle - the prompt still standing behind her. Everything that resolves a prompt
    /// does fire a hook: approve it and the tool runs (PostToolUse), deny it and the
    /// model carries on (PermissionDenied, or the next tool), cut it with Esc and the
    /// turn ends (Stop, which the hook turns into `stopped`), close the terminal and
    /// the pid dies. So a `waiting` now stands for as long as its session does, and
    /// the wave is what stops after a while, not the line.

    private struct Signal {
        var state: ClaudeState
        var detail: String
        var age: TimeInterval
        /// The session's `claude` process, 0 when the hook could not tell.
        var pid: pid_t = 0
        /// Which hook wrote the line. `PermissionRequest` matters: it is the one
        /// `waiting` that names the tool, and the only one `noticeApproval` watches.
        var source = ""
        var url: URL?
        var at = Date.distantPast
        var project = ""
    }

    /// A fresh notice outranks work: a `done` that just landed, or a `waiting` still
    /// standing, comes to the front even while another session types away. It used to
    /// be the other way around - newest *working* session first - and a terminal killed
    /// mid-answer (no SessionEnd, file frozen at `running`) muted every celebration
    /// and every permission prompt from the live sessions for the whole 15 minutes it
    /// took the corpse to go stale. The notices are the point of her; they must not
    /// lose to a ghost. A `done` expires on its own (`doneGoesQuiet`); a `waiting`
    /// is cleared by whatever answers it, so the working session gets the floor back
    /// the moment something happens.
    /// Every live session file. Ranking happens in `pick`; event detection needs
    /// them all, including a `done` long past its moment in front.
    // Situations no hook ever closes:
    /// the last helper finished and Claude never came back for its result
    static let wakeWait: TimeInterval = 30
    /// Esc before the first reply: nothing fires at all (no Stop, no PostToolUse)
    static let escWait: TimeInterval = 150
    /// background helpers that never reported finishing
    static let parkedWait: TimeInterval = 30 * 60
    /// a compaction whose PostCompact never came (older Claude Code)
    static let compactWait: TimeInterval = 10 * 60

    /// What a file nobody has touched in a while really means.
    private static func settle(_ st: ClaudeState, source: String, transcript: String,
                               age: TimeInterval) -> (ClaudeState, TimeInterval) {
        if st == .thinking, source == "SubagentStop", age > wakeWait { return (.done, age - wakeWait) }
        if st == .thinking, source == "UserPromptSubmit", age > escWait {
            // only if the transcript stopped moving too: long reasoning does move it
            var quiet = true
            if !transcript.isEmpty,
               let m = (try? FileManager.default.attributesOfItem(atPath: transcript))?[.modificationDate] as? Date {
                quiet = Date().timeIntervalSince(m) > escWait
            }
            if quiet { return (.stopped, age) }
        }
        if st == .thinking, source == "PreCompact", age > compactWait { return (.idle, age) }
        if st == .delegating, source == "Stop" || source == "SubagentStop", age > parkedWait { return (.stopped, age) }
        return (st, age)
    }

    // ---- what Claude Code itself publishes ----
    //
    // Every Claude Code session (terminal, VS Code, the Code tab of Claude Desktop, the
    // SDK) keeps ~/.claude/sessions/<pid>.json with its state as it is right now: "busy"
    // while it answers or has helpers running, "waiting" (+ waitingFor) when it is
    // blocked on you, "idle" once everything is over ("shell": over, with commands left
    // in the background). It is what Claude Code's own session view reads. It rules the
    // LEVEL: an Esc, an answered prompt, or the real end of a turn with helpers show at
    // once, with no invented waits. The hooks still bring the detail (what it reads, what
    // it runs) and how it ended (fine, cut, error). Undocumented: without that file (an
    // older Claude Code) everything works as before, on hooks alone.
    struct Presence {
        let pid: pid_t
        let status: String
        let waitingFor: String
        let at: Date
        let startedAt: Date
        let cwd: String
        let entrypoint: String
    }
    static let presenceDir: URL = {
        let env = ProcessInfo.processInfo.environment
        if let p = env["COMPA_PRESENCE"], !p.isEmpty { return URL(fileURLWithPath: p) }
        let base = env["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return base.appendingPathComponent("sessions")
    }()
    /// "idle" has to last this long before it closes a turn no hook closed.
    static let idleSettle: TimeInterval = 2
    /// Claude Code inside Claude Desktop: its CPU is the app's, so the app is not guessed.
    static let inDesktop: Set<String> = ["claude-desktop", "local-agent"]
    private(set) var presence: [String: Presence] = [:]
    /// Claude Code in Claude Desktop working (or just finished): no CPU guessing meanwhile.
    private(set) var desktopCodeBusy = false
    private var desktopCodeLast: CFTimeInterval = -100

    private static func readPresence() -> [String: Presence] {
        var out: [String: Presence] = [:]
        let urls = (try? FileManager.default.contentsOfDirectory(at: presenceDir, includingPropertiesForKeys: nil)) ?? []
        for u in urls where u.pathExtension == "json" {
            guard let d = try? Data(contentsOf: u),
                  let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let sid = j["sessionId"] as? String, let status = j["status"] as? String,
                  let pidN = j["pid"] as? NSNumber else { continue }
            let pid = pid_t(pidN.int32Value)
            // removed on exit; one left behind is checked against its process
            guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { continue }
            func ms(_ k: String) -> Date? { (j[k] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } }
            out[sid] = Presence(pid: pid, status: status, waitingFor: j["waitingFor"] as? String ?? "",
                                at: ms("statusUpdatedAt") ?? ms("updatedAt") ?? .distantPast,
                                startedAt: ms("startedAt") ?? .distantPast,
                                cwd: j["cwd"] as? String ?? "", entrypoint: j["entrypoint"] as? String ?? "")
        }
        return out
    }

    /// "dialog open" is a menu of yours open in the terminal (/config...): not waiting on you.
    private static func realWait(_ p: Presence) -> Bool { p.status == "waiting" && p.waitingFor != "dialog open" }
    private static func waitDetail(_ w: String) -> String { w.contains("input") ? "input" : "permission" }

    /// What the hook says, corrected by what Claude Code says.
    private static func blend(_ s0: Signal, _ p: Presence, now: Date) -> Signal {
        var s = s0
        let at = max(s.at, p.at)
        func set(_ st: ClaudeState, _ d: String, _ when: Date? = nil) {
            let w = when ?? at
            s.state = st; s.detail = d; s.at = w; s.age = max(0, now.timeIntervalSince(w))
        }
        func since(_ d: Date) -> TimeInterval { now.timeIntervalSince(d) }
        if realWait(p) {
            // a work hook newer than the wait: you already answered, the file just lags
            if s.state.isWorking, s.at > p.at.addingTimeInterval(1.5) { return s }
            if s.state != .waiting { set(.waiting, waitDetail(p.waitingFor)) } else { s.at = at }
        } else if p.status == "waiting" {
            // a menu of yours: if the hook said "waiting", that prompt has been answered
            if s.state == .waiting, p.at > s.at { let (st, d) = workAfterApproval(s.detail); set(st, d) }
        } else if p.status == "busy" {
            if s.state.isWorking { return s }
            if s.state == .waiting { let (st, d) = workAfterApproval(s.detail); set(st, d); return s }
            if s.state == .done || s.state == .stopped || s.state == .error {
                // busy since AFTER the end: a new turn (its hook is on its way)
                if p.at > s.at { set(.thinking, ""); return s }
                // busy since BEFORE: the main thread ended (Stop) but helpers are still
                // running in the background. No "done" yet: the notice comes when it all
                // ends, once. For the first seconds, in case the "idle" is about to land,
                // without changing face.
                if since(s.at) < idleSettle { set(.thinking, "", s.at) } else { set(.delegating, "helpers") }
            } else { set(.thinking, "") }
        } else if p.status == "idle" || p.status == "shell" {
            if !s.state.isWorking && s.state != .waiting { return s }
            if since(p.at) < idleSettle { return s }                 // the end hook is on its way
            if s.at > p.at, since(s.at) < 10 { return s }            // you just wrote to it: the hook rules a while
            // over with no hook closing it: an Esc, a prompt cut short, helpers ending...
            if s.state == .delegating || s.source == "SubagentStop" { set(.done, s.detail == "helpers" ? "" : s.detail, p.at) }
            else if s.source == "PreCompact" || s.source == "PostCompact" { set(.idle, "", p.at) }
            else { set(.stopped, "", p.at) }
        }
        return s
    }

    /// A session only Claude Code knows about (no hooks): what can be said.
    private static func fromPresence(_ key: String, _ p: Presence, now: Date) -> Signal? {
        let st: ClaudeState
        if realWait(p) { st = .waiting }
        else if p.status == "busy" { st = .thinking }
        else if p.at.timeIntervalSince(p.startedAt) > 5 { st = .done }   // it has worked: "idle" = finished
        else { return nil }                                             // just opened, nothing done yet
        let project = String((p.cwd.split(separator: "/").last.map(String.init) ?? "").prefix(34))
        return Signal(state: st, detail: st == .waiting ? waitDetail(p.waitingFor) : "",
                      age: max(0, now.timeIntervalSince(p.at)), pid: p.pid, source: "presence",
                      url: sessionsDir.appendingPathComponent(key), at: p.at, project: project)
    }

    private static func readSignals(presence: [String: Presence] = [:]) -> [Signal] {
        let fm = FileManager.default
        let now = Date()
        var known = Set<String>()
        let urls = (try? fm.contentsOfDirectory(at: sessionsDir,
                                                includingPropertiesForKeys: [.contentModificationDateKey],
                                                options: [.skipsHiddenFiles])) ?? []
        var out: [Signal] = []
        for u in urls where u.lastPathComponent.hasSuffix(".tmp") == false {
            guard let at = try? u.resourceValues(forKeys: [.contentModificationDateKey])
                                 .contentModificationDate,
                  let raw = try? String(contentsOf: u, encoding: .utf8) else { continue }
            let parts = raw.trimmingCharacters(in: .newlines).components(separatedBy: "\t")
            let pid = parts.count > 2 ? (pid_t(parts[2]) ?? 0) : 0
            var alive = false
            if pid > 0 {
                alive = kill(pid, 0) == 0 || errno == EPERM
                // The session's process is gone: whatever the file says, nobody is
                // saying it. A terminal closed with the window button never sends
                // SessionEnd.
                if !alive {
                    try? fm.removeItem(at: u)
                    try? fm.removeItem(at: u.deletingLastPathComponent()
                                            .appendingPathComponent("." + u.lastPathComponent + ".pid"))
                    continue
                }
            }
            let age = Date().timeIntervalSince(at)
            if !alive, age > signalGoesStale { continue }
            let source = parts.count > 3 ? parts[3] : ""
            if let p = presence[u.lastPathComponent] {
                known.insert(u.lastPathComponent)
                let raw = Signal(state: ClaudeState(rawValue: parts.first ?? "") ?? .thinking,
                                 detail: parts.count > 1 ? parts[1] : "", age: age, pid: pid, source: source,
                                 url: u, at: at, project: parts.count > 4 ? parts[4] : "")
                out.append(blend(raw, p, now: now))
                continue
            }
            let (s, effectiveAge) = settle(ClaudeState(rawValue: parts.first ?? "") ?? .thinking,
                                           source: source, transcript: parts.count > 5 ? parts[5] : "",
                                           age: age)
            out.append(Signal(state: s, detail: parts.count > 1 ? parts[1] : "",
                              age: effectiveAge, pid: pid, source: source,
                              url: u, at: at, project: parts.count > 4 ? parts[4] : ""))
        }
        for (key, p) in presence where !known.contains(key) && !key.hasPrefix(".") && !key.contains("/") {
            if let s = fromPresence(key, p, now: now) { out.append(s) }
        }
        return out
    }

    /// The level says what she *does*, so it ranks: a prompt waiting on you, then
    /// work, and only when no session is working a `done` that just landed. Work
    /// outranks a finished session on purpose: while anything is still running she
    /// stays at work, so seeing her idle means everything is really finished. The
    /// sessions that finish along the way are not lost - each one is an event, and
    /// the brain announces it over the work without stopping it.
    private static func pick(_ all: [Signal]) -> Signal? {
        var bestNotice: Signal?, bestWaiting: Signal?, bestWorking: Signal?
        for sig in all {
            switch sig.state {
            case .done, .stopped, .error:
                if sig.age < doneGoesQuiet, bestNotice == nil || sig.at > bestNotice!.at { bestNotice = sig }
            case .waiting:
                if bestWaiting == nil || sig.at > bestWaiting!.at { bestWaiting = sig }
            case _ where sig.state.isWorking:
                if bestWorking == nil || sig.at > bestWorking!.at { bestWorking = sig }
            default: break
            }
        }
        if let w = bestWaiting { return w }
        if let w = bestWorking { return w }
        if let d = bestNotice { return d }
        // legacy: the bare busy file, which says nothing beyond "she is working"
        if let at = try? signalFile.resourceValues(forKeys: [.contentModificationDateKey])
                                   .contentModificationDate,
           Date().timeIntervalSince(at) < signalGoesStale {
            return Signal(state: .thinking, detail: "", age: Date().timeIntervalSince(at))
        }
        return nil
    }

    /// Turns changes in the session files into events. Keyed on the file's mtime, so
    /// a `done` is noticed however long after it landed, and a file rewritten with the
    /// same state (two prompts in a row) is still news.
    private func track(_ all: [Signal]) {
        var now: [String: (state: ClaudeState, at: Date)] = [:]
        for s in all {
            guard let key = s.url?.lastPathComponent else { continue }
            now[key] = (s.state, s.at)
            let before = seen[key]
            if let b = before, b.at == s.at, b.state == s.state { continue }
            let kind: ClaudeEvent.Kind?
            switch s.state {
            case .done:    kind = before?.state == .done ? nil : .finished
            case .error:   kind = before?.state == .error ? nil : .failed
            case .waiting: kind = before?.state == .waiting ? nil : .needsYou
            case .stopped: kind = .engaged
            case _ where s.state.isWorking:
                kind = (before.map { $0.state.isWorking } ?? false) ? nil : .engaged
            default: kind = nil
            }
            guard let k = kind else { continue }
            // a session without hooks that shows up already finished: we never saw it work
            if before == nil, s.source == "presence", k != .needsYou { continue }
            // At launch only a prompt that is still standing matters: an answer that
            // finished before she was running is old news.
            if !primed && k != .needsYou { continue }
            emit(ClaudeEvent(kind: k, session: key, project: s.project,
                                      detail: s.detail, quiet: !primed))
        }
        for key in seen.keys where now[key] == nil {
            emit(ClaudeEvent(kind: .gone, session: key, project: "", detail: "", quiet: true))
        }
        seen = now
        primed = true
    }

    // ---- the answered permission prompt ----
    //
    // There is a hook for the prompt going up (PermissionRequest) and none for it
    // coming down: approve a command and the next thing Claude Code says is
    // PostToolUse, when the command has *finished*. For a build that takes a minute
    // she spent that minute asking "ok to run the build?" at someone who had already
    // said yes. What does change the instant you approve is the process tree: the
    // command is spawned as a child of the session's `claude`. So while a prompt
    // stands she watches that process's children, and a new one that survives two
    // polls means the prompt was answered - the file is rewritten as the work it
    // turned into, and the hooks take over again from there. Her own hooks are
    // children too, but they live for a few milliseconds and say ".compa/hook" in their
    // command line, so they are skipped.

    private var approvalWatch: (url: URL, at: Date, baseline: Set<pid_t>, seen: [pid_t: Int])?

    /// Rewrites the session file when its prompt looks answered. Returns the new
    /// signal, or nil when nothing changed.
    private func noticeApproval(_ sig: Signal) -> Signal? {
        guard sig.state == .waiting, sig.source == "PermissionRequest", sig.pid > 0,
              let url = sig.url else { approvalWatch = nil; return nil }
        let kids = Self.children(of: sig.pid)
        guard var w = approvalWatch, w.url == url, w.at == sig.at else {
            approvalWatch = (url, sig.at, kids, [:])
            return nil
        }
        var seen: [pid_t: Int] = [:]
        for k in kids where !w.baseline.contains(k) {
            let n = (w.seen[k] ?? 0) + 1
            if n == 1, Self.commandLine(of: k).contains(".compa/hook") { w.baseline.insert(k); continue }
            seen[k] = n
        }
        w.seen = seen
        approvalWatch = w
        guard seen.values.contains(where: { $0 >= 2 }) else { return nil }
        approvalWatch = nil
        // the file may have moved on in the meantime; only a standing prompt is rewritten
        guard (try? String(contentsOf: url, encoding: .utf8))?.hasPrefix("waiting\t") == true else { return nil }
        let (state, detail) = Self.workAfterApproval(sig.detail)
        let line = "\(state.rawValue)\t\(detail)\t\(sig.pid)\tapp\t\(sig.project)\n"
        guard (try? line.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        return Signal(state: state, detail: detail, age: 0, pid: sig.pid, source: "app", url: url, at: Date(),
                      project: sig.project)
    }

    /// "run the tests" was the question; "running the tests" is the answer.
    private static func workAfterApproval(_ ask: String) -> (ClaudeState, String) {
        let verbs: [(String, ClaudeState)] = [("run ", .running), ("use ", .running), ("edit ", .writing),
                                              ("read ", .reading), ("fetch ", .searching),
                                              ("search ", .searching), ("send a helper", .delegating)]
        for (v, s) in verbs where ask.hasPrefix(v) {
            return (s, String(ask.dropFirst(v.count)).trimmingCharacters(in: .whitespaces))
        }
        return (.thinking, "")
    }

    private static func children(of pid: pid_t) -> Set<pid_t> {
        var buf = [pid_t](repeating: 0, count: 512)
        let n = proc_listchildpids(pid, &buf, Int32(buf.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return [] }
        return Set(buf[0..<Int(n)])
    }

    /// argv of a process, NULs turned into spaces. Empty when it is already gone.
    private static func commandLine(of pid: pid_t) -> String {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return "" }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return "" }
        return String(decoding: buf[4..<size].map { $0 == 0 ? 0x20 : $0 }, as: UTF8.self)
    }

    /// Just the signal files: a readdir and a couple of short reads. Cheap enough to
    /// run several times a second, which is what makes her look like she is following
    /// along instead of catching up.
    func poll(now: CFTimeInterval) {
        // A report only outranks the CPU guess while it is saying something is
        // happening - `readSignal` already dropped the notices that expired, so once
        // the last session has been sitting at `done` for a few seconds, nobody is
        // reporting any more and the desktop app gets the floor back. Otherwise one
        // open terminal would mute it all day.
        presence = Self.readPresence()
        if presence.values.contains(where: { Self.inDesktop.contains($0.entrypoint) && $0.status == "busy" }) {
            desktopCodeLast = now
        }
        // and a few seconds after: its CPU takes a moment to settle
        desktopCodeBusy = now - desktopCodeLast < 10
        let all = screen(Self.readSignals(presence: presence))
        track(all)
        sessions = all.compactMap { s in
            s.url.map { SessionInfo(key: $0.lastPathComponent, project: s.project, state: s.state, age: s.age,
                                    detail: s.detail, at: s.at) }
        }.sorted { $0.at > $1.at }
        var sig = Self.pick(all)
        // Claude Code's own file already says when a prompt is answered; the process
        // trick is only for sessions without it
        if let s = sig, presence[s.url?.lastPathComponent ?? ""] == nil, let answered = noticeApproval(s) { sig = answered }
        isSignalled = sig != nil
        if let sig {
            state = sig.state
            detail = sig.detail
            project = sig.project
        } else if Self.fakeBusy {
            state = now.truncatingRemainder(dividingBy: 22) < 9 ? .thinking : .idle
            detail = ""; project = ""
        } else {
            // no one is reporting, so all we have is the CPU guess - which can say
            // "working" and nothing more
            state = snapshot.busy && hidden["desktop"] == nil ? .thinking : .idle
            detail = ""; project = ""
        }
    }

    /// The whole picture, including the parts that cost a syscall storm. Hands the
    /// expensive half to the queue and returns.
    /// One pet per session gives Claude Desktop its own pet, which has to keep guessing
    /// even while a Claude Code session talks (the classic pet stops guessing then: a
    /// hook is a fact). The flock turns this on while it runs.
    var keepsGuessing = false
    /// Claude Desktop itself, apart from Claude Code: open, and answering (by CPU).
    private(set) var desktopRunning = false
    var desktopBusy: Bool { snapshot.busy }

    func refresh(now: CFTimeInterval) {
        poll(now: now)
        let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == Self.bundleID }
        desktopRunning = !apps.isEmpty
        isRunning = !apps.isEmpty || isSignalled
        isFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.bundleID

        if Self.fakeBusy {
            isRunning = true
            publish(Snapshot(busy: state.isWorking, cpu: 0, center: nil))
            return
        }
        // an explicit signal beats any amount of guessing at CPU
        if (isSignalled && !keepsGuessing) || desktopCodeBusy {
            // ...and while it does, nothing is sampling, so the CPU counters go stale.
            // Coming back to them, the first delta would be spread over the whole gap:
            // a smeared number that means nothing and poisons the floor with it. Zeroing
            // the mark makes the next sample a baseline instead. On the queue, so it
            // can't race a sample that is still in flight.
            queue.async { self.lastSample = 0 }
            // busy is the *guess*, and while a signal stands nothing is being guessed -
            // publishing the signal's state here left a stale busy=true behind after
            // the signal vanished, and `poll` read it as "the CPU says working" for the
            // next second and a half. That ghost hop through thinking is what let a
            // dead session's disappearance end in a celebration.
            publish(Snapshot(busy: false, cpu: snapshot.cpu, center: snapshot.center))
            return
        }
        guard let main = apps.first else {
            publish(Snapshot())
            return
        }
        guard !sampling else { return }     // a slow sample must never queue up behind itself
        sampling = true
        let pid = main.processIdentifier
        // NSScreen is main-thread only, so the flip the window geometry needs travels
        // with the request instead of being looked up on the queue
        let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
        let front = isFrontmost
        let input = front ? Self.secondsSinceInput() : .infinity
        queue.async { [self] in
            let s = sample(mainPID: pid, now: now, screenTop: screenTop, inFront: front,
                           inputAge: input)
            publish(s)
            DispatchQueue.main.async { self.sampling = false }
        }
    }

    /// Seconds since you last typed, scrolled or clicked - the three things that
    /// make Claude Desktop burn CPU on *your* behalf. Needs no permission: it is the
    /// same call the idle timer uses, just narrowed to the events that cost cycles.
    private static func secondsSinceInput() -> TimeInterval {
        [CGEventType.keyDown, .scrollWheel, .leftMouseDown].map {
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0)
        }.min() ?? .infinity
    }

    /// While you are typing into Claude, a guessed stretch may not start: the load
    /// is yours. Two and a half seconds is longer than any pause between keystrokes
    /// and shorter than the time it takes the first tokens to show up after Enter.
    private static let typingGate: TimeInterval = 2.5
    /// An answer in the desktop app begins right after you send something. A modest
    /// load that turns up with Claude in front but nothing sent for this long is the
    /// app doing its own housekeeping while you read, not an answer.
    private static let askedWindow: TimeInterval = 20

    private func sample(mainPID: pid_t, now: CFTimeInterval, screenTop: CGFloat,
                        inFront: Bool, inputAge: TimeInterval) -> Snapshot {
        if now - pidsRefreshed > 8 { pids = Self.claudePIDs(fallback: mainPID); pidsRefreshed = now }
        let center = Self.frontWindowCenter(pid: mainPID, screenTop: screenTop)

        let total = pids.reduce(0.0) { $0 + Self.cpuSeconds(pid: $1) }
        defer { lastCPUTime = total; lastSample = now }
        guard lastSample > 0, now > lastSample, total >= lastCPUTime else {
            return Snapshot(busy: now - busySince < holdFor, cpu: 0, center: center)
        }

        let cpu = (total - lastCPUTime) / (now - lastSample)
        let floor = floorHistory.min() ?? 0
        // once it has called her busy the bar to stay busy drops, so the pauses
        // between tokens don't make her fall out in the middle of an answer
        let busy = now - busySince < holdFor
        if !busy { holdFor = Self.busyHold }
        let hot = cpu > floor + (busy ? 0.06 : 0.18) && cpu > (busy ? 0.05 : 0.20)
        // already answering, a small but steady load is the app's animation waiting on a
        // tool: not new work, but not the end either
        // what you burn yourself using the app (reading, scrolling) does not stretch the task
        let yours = inFront && inputAge < Self.typingGate
        let warmNow = busy && !hot && !yours && cpu > floor + Self.warm && now - lastHotAt < Self.warmLimit
        if hot && !yours {
            if busy, now - lastHotAt >= Self.toolGap { holdFor = Self.toolHold }
            lastHotAt = now
        }
        hotStreak = hot ? hotStreak + 1 : 0
        // Sitting untouched in the background, the desktop app throws 25-70% CPU bursts
        // every half minute or so - measured, 22 of them in ten idle minutes. By size
        // alone they are indistinguishable from an answer. Two things do separate them,
        // both measured over 648 samples of that noise:
        //   - the chatter arrives while you are working somewhere else, and
        //   - it is always a *single* sample; it never held above 0.5 for two in a row.
        // So there are two ways in. Looking at Claude, a modest sustained load is enough
        // and she reacts immediately. Looking elsewhere, it takes a load the background
        // never reaches twice running - which still catches the case where you ask
        // something and switch away before she noticed.
        // the floor stands for Claude sitting still, so samples taken mid-answer must
        // not feed it: they used to, and a long answer would raise its own floor until
        // it stopped looking busy - she'd celebrate halfway through
        if !hot {
            floorHistory.append(cpu)
            if floorHistory.count > 60 { floorHistory.removeFirst() }
        }
        // hold the busy state briefly so short gaps between tokens don't flicker
        let loud = cpu > 0.5
        loudStreak = loud ? loudStreak + 1 : 0
        // The "looking at Claude" way in was the noisy one, and for a reason the
        // thresholds could never fix: with Claude in front, most of what makes it
        // burn CPU is *you* - typing a message, scrolling a long answer, clicking
        // through chats - and she read all of it as "thinking…" while you were the
        // one working. So a guessed stretch can't start while you are typing there,
        // and the modest-load way in is only open for a short while after you did
        // something: an answer follows a send, the housekeeping doesn't. The loud
        // way in stays as it was, for the task you kicked off and walked away from.
        let typing = inFront && inputAge < Self.typingGate
        let asked = inFront && inputAge < Self.askedWindow
        let starts = hotStreak >= 2 && !typing && (asked || loudStreak >= 2)
        if busy ? (hot && !yours) || warmNow : starts { busySince = now }
        return Snapshot(busy: now - busySince < holdFor, cpu: cpu, center: center)
    }

    private static func claudePIDs(fallback: pid_t) -> [pid_t] {
        let cap = Int(proc_listallpids(nil, 0)) + 128
        var buf = [pid_t](repeating: 0, count: max(cap, 512))
        let n = proc_listallpids(&buf, Int32(buf.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return [fallback] }
        var out: [pid_t] = []
        var path = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        for pid in buf[0..<Int(n)] where pid > 0 {
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            if String(cString: path).contains("/Claude.app/") { out.append(pid) }
        }
        return out.isEmpty ? [fallback] : out
    }

    /// Mach ticks to seconds. On Apple Silicon `ri_user_time` and `ri_system_time`
    /// come back in mach absolute time units, not nanoseconds - the factor here is
    /// 125/3, about 41.7. Dividing by 1e9 as if they were nanoseconds made every CPU
    /// reading forty-one times too small, so the desktop app looked permanently idle
    /// no matter how hard it was working. It only looks right on Intel, where the
    /// timebase happens to be 1:1.
    private static let tickToSeconds: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom) / 1e9
    }()

    private static func cpuSeconds(pid: pid_t) -> Double {
        var usage = rusage_info_current()
        let rc = withUnsafeMutablePointer(to: &usage) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard rc == 0 else { return 0 }
        return Double(usage.ri_user_time + usage.ri_system_time) * tickToSeconds
    }

    /// Window geometry only - this needs no screen-recording permission.
    private static func frontWindowCenter(pid: pid_t, screenTop: CGFloat) -> CGPoint? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        var best: CGRect?
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary),
                  r.width > 300, r.height > 200 else { continue }
            if best == nil || r.width*r.height > best!.width*best!.height { best = r }
        }
        guard let r = best else { return nil }
        // CGWindow origin is top-left of the primary display; AppKit is bottom-left
        return CGPoint(x: r.midX, y: screenTop - r.midY)
    }
}
