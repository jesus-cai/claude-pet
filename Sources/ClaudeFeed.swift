import AppKit

/// What a pet's brain needs to know about Claude. The combined probe (one pet that
/// sums up every session - the classic mode) is one; a single session's feed (one
/// pet per session) is another. The brain cannot tell them apart, which is the point:
/// the classic mode runs exactly the code it always ran.
protocol ClaudeFeed: AnyObject {
    var state: ClaudeState { get }
    var detail: String { get }
    var project: String { get }
    var isSignalled: Bool { get }
    var isBusy: Bool { get }
    var isFrontmost: Bool { get }
    var windowCenter: CGPoint? { get }
    var sessions: [ClaudeProbe.SessionInfo] { get }
    /// The session this feed follows, or nil for the combined one. A single
    /// session's pet carries the project on its label, so its balloon leaves it out.
    var key: String? { get }
    func refresh(now: CFTimeInterval)
    func poll(now: CFTimeInterval)
    func takeEvents() -> [ClaudeEvent]
}

extension ClaudeProbe: ClaudeFeed {
    var key: String? { nil }
}

/// One Claude Code session, for its own pet. Reads nothing itself: whoever runs the
/// pets polls the shared probe once, and every feed catches up from what it read.
final class SessionFeed: ClaudeFeed {
    let probe: ClaudeProbe
    let sessionKey: String
    var key: String? { sessionKey }

    private(set) var state: ClaudeState = .idle
    private(set) var detail = ""
    private(set) var project = ""
    private(set) var isSignalled = false
    /// False once the session is gone: time for its pet to say goodbye.
    private(set) var exists = false
    private(set) var sessions: [ClaudeProbe.SessionInfo] = []
    private var cursor: Int

    var isBusy: Bool { state.isWorking }
    var isFrontmost: Bool { false }
    var windowCenter: CGPoint? { nil }

    init(probe: ClaudeProbe, key: String) {
        self.probe = probe
        self.sessionKey = key
        cursor = probe.seq
        update()
    }

    func refresh(now: CFTimeInterval) { update() }
    func poll(now: CFTimeInterval) { update() }

    func takeEvents() -> [ClaudeEvent] {
        // up to date first: an event has to arrive together with the state that explains it
        update()
        let out = probe.log.filter { $0.seq > cursor && $0.event.session == sessionKey }.map { $0.event }
        cursor = probe.seq
        return out
    }

    private func update() {
        guard let s = probe.sessions.first(where: { $0.key == sessionKey }) else {
            exists = false; isSignalled = false; sessions = []
            state = .idle; detail = ""        // project stays: the label outlives the session
            return
        }
        exists = true; isSignalled = true; sessions = [s]
        var st = s.state
        // like the combined one: an ending only holds the level for a few seconds
        if st == .done || st == .stopped || st == .error, s.age >= ClaudeProbe.doneGoesQuiet { st = .idle }
        state = st; detail = s.detail; project = s.project
    }
}

/// Claude Desktop, guessed from its CPU, for its own pet. Unlike the combined feed it
/// does not give way to Claude Code: each has its pet. Its notices come from the
/// brain's guess when the busy stretch ends, as in the classic mode.
final class DesktopFeed: ClaudeFeed {
    let probe: ClaudeProbe
    init(probe: ClaudeProbe) { self.probe = probe }
    var key: String? { "desktop" }
    var state: ClaudeState { probe.desktopBusy ? .thinking : .idle }
    var detail: String { "" }
    var project: String { "Claude Desktop" }
    var isSignalled: Bool { false }
    var isBusy: Bool { state.isWorking }
    var isFrontmost: Bool { probe.isFrontmost }
    var windowCenter: CGPoint? { probe.windowCenter }
    var sessions: [ClaudeProbe.SessionInfo] { [] }
    func refresh(now: CFTimeInterval) {}
    func poll(now: CFTimeInterval) {}
    func takeEvents() -> [ClaudeEvent] { [] }
}
