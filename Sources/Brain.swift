import AppKit

enum Activity { case idle, walking, turning, waving, sleeping, working, celebrating, failed, dragged }

/// Decides what the pet is doing and turns that into a frame, 60 times a second.
///
/// Two ways Claude reaches her. The *level* - what Claude is doing right now - drives
/// the animation and the working line in the balloon. The *events* - a turn finished,
/// a prompt went up - drive the notices, and a notice stays until you have seen it:
/// you click her, the same session starts working again, or you have been at the
/// machine for a while with it on screen. That is the difference with the first
/// version, where a "done!" lasted three seconds and was gone if you were looking at
/// another window - or never showed at all if the screen was asleep when it landed.
final class Brain {
    var wanders = true
    var followsCursor = true
    var reactsToClaude = true
    var announces = true

    /// Puts a line in the speech balloon over her head: text, seconds, tone, and a
    /// dim tag in front (the project). `.infinity` holds it until the next call.
    var speak: ((String, CFTimeInterval, BubbleTone, String) -> Void)?
    /// ...and takes it down again.
    var hush: (() -> Void)?
    /// Something worth a sound or a system notification happened.
    var alert: ((ClaudeEvent) -> Void)?

    /// A finished turn (or a failed one) that you have not seen yet.
    struct Notice {
        enum Kind { case done, error }
        let kind: Kind
        let session: String
        let project: String
        let text: String
        /// Seconds she has held it up while you were at the machine.
        var seenFor: CFTimeInterval = 0
        /// Arrival order, newest highest.
        var order = 0
    }
    /// Unseen notices, one per session: two answers that land while you are away
    /// are both still there when you come back.
    private(set) var notices: [String: Notice] = [:]
    private var noticeCount = 0
    /// The newest one, for whoever only needs one.
    var notice: Notice? { notices.values.max { $0.order < $1.order } }

    /// A session that finished while others still work: said over the work for a
    /// few seconds, without stopping it.
    private var flash: (text: String, tone: BubbleTone, tag: String)?
    private var flashUntil: CFTimeInterval = 0
    /// Is some other session still working (or waiting on you)? Then a finish is
    /// news, not the end of the stretch.
    private var busyElsewhere: Bool { claude.state.isWorking || claude.state == .waiting }

    private func post(_ n: Notice) {
        var n = n
        noticeCount += 1
        n.order = noticeCount
        notices[n.session] = n
    }
    /// How long a notice stays up once you are around to see it. Time away from the
    /// keyboard does not count: come back after lunch and it is still there.
    static let noticeLife: CFTimeInterval = 45

    private(set) var activity: Activity = .idle
    private(set) var x: CGFloat = 0                // screen x of her feet
    private(set) var facing: CGFloat = 1
    /// Last blink value handed out, for the debug line.
    private(set) var lidNow: CGFloat = 0

    /// Atlas pets: which row is playing and since when, and where she looks.
    private(set) var clip: SpriteClip = .idle
    private var clipStarted: CFTimeInterval = 0
    private(set) var look: Int?
    /// Set by the app when the pet has the 16 look directions (atlas v2).
    var hasLook = false
    /// Set by the app for pets that walk at a fixed speed (atlas pets).
    var walkOverride: CGFloat?
    /// Set by the app when the pet has a talking strip. She "says" each new line in
    /// the balloon: the mouth moves for about as long as it takes to read it.
    var hasTalk = false
    private var talkUntil: CFTimeInterval = 0
    /// The pet's personality: which row plays for a moment, and what she says.
    private var reactionClips: [Activity: SpriteClip] = [:]
    private var lines: [String: [String]] = [:]

    func setPersonality(reactions: [String: String], lines: [String: [String]]) {
        let moments: [String: Activity] = ["done": .celebrating, "drag": .dragged, "wave": .waving,
                                           "error": .failed, "work": .working]
        var map: [Activity: SpriteClip] = [:]
        for (k, v) in reactions {
            if let a = moments[k], let c = SpriteClip(name: v) { map[a] = c }
        }
        reactionClips = map
        self.lines = lines.filter { !$0.value.isEmpty }
    }

    private func say(_ key: String, _ fallback: [String]) -> String {
        (lines[key] ?? fallback).randomElement() ?? fallback[0]
    }

    private var t: CFTimeInterval = 0
    private var stateStarted: CFTimeInterval = 0
    private var nextDecision: CFTimeInterval = 4
    private var walkTarget: CGFloat = 0
    private var nextBlink: CFTimeInterval = 3
    private var blinkStart: CFTimeInterval = -10
    private var doubleBlink = false
    private var turned = false
    private var landedAt: CFTimeInterval = -10
    private var lookX: CGFloat = 0                 // smoothed gaze, -1...1
    private var lookY: CGFloat = 0
    let claude: ClaudeFeed
    private var claudeSampled: CFTimeInterval = -10
    private var claudePolled: CFTimeInterval = -10
    /// nil until the first sample: a session that was already finished when she
    /// launched must not be celebrated as if it had just landed in front of her.
    private var lastState: ClaudeState?
    /// Did a report (as opposed to the CPU guess) drive any part of the busy stretch
    /// she is currently watching? See `react`.
    private var stretchSignalled = false
    private var busyStarted: CFTimeInterval = 0
    private var watching = false
    /// What the balloon says while Claude works (or waits on you). Recomputed by
    /// `react`, shown by `updateBalloon`.
    private var workLine = ""
    /// The line currently up, so the same one is never said twice (which would
    /// restart the pop). Also printed on the debug line.
    private(set) var lastLine = ""
    private var lastTone: BubbleTone = .working
    private var lastTag = ""
    /// The variant of "thinking…" picked for this answer. Chosen once per turn.
    private var opener = Brain.startLines[0]
    /// Has this stretch already shown a tool line (reading, running…)? After that a
    /// bare `thinking` is the model reading a tool's output, not a turn starting.
    private var sawTool = false
    /// When the state last changed, so a bare `thinking` that lands between two
    /// tools can hold the previous line for a beat instead of flickering.
    private var stateChangedAt: CFTimeInterval = 0
    private static let toolLineGrace: CFTimeInterval = 2
    private var nextNag: CFTimeInterval = 0
    private var waitingSince: CFTimeInterval = 0
    /// Away from the keyboard for a while; coming back is a moment to wave.
    private var wasAway = false
    private var idleAt: CFTimeInterval = 0
    private var idleSampled: CFTimeInterval = -10
    private var lastPose = Pose()
    private var blendFrom: Pose?
    private var blendStart: CFTimeInterval = 0
    private let blendTime: CFTimeInterval = 0.24

    /// How long a burst of CPU has to last before she treats it as an answer worth
    /// celebrating. Only the Claude Desktop guess pays this: a `done` from a hook is a
    /// fact, and gets its party even if the whole turn took two seconds.
    static let guessedAnswer: CFTimeInterval = 12
    static let failedTime: CFTimeInterval = 2.2

    static let startLines = ["thinking…", "here we go…", "on it…", "let me see…"]
    private static let doneLines  = ["done!", "all yours ✨", "it's ready!", "go read it!",
                                     "finished!", "that's it!"]

    /// What goes in the balloon for a given state. Deterministic on purpose - the
    /// same situation has to produce the same string every frame.
    private static func line(for s: ClaudeState, detail: String, opener: String) -> String {
        let d = detail.trimmingCharacters(in: .whitespaces)
        switch s {
        case .thinking:   return d.isEmpty ? opener : d
        case .reading:    return d.isEmpty ? "reading…"   : "reading \(d)"
        case .writing:    return d.isEmpty ? "writing…"   : "writing \(d)"
        case .running:    return d.isEmpty ? "running…"   : "running \(d)"
        case .searching:  return d.isEmpty ? "searching…" : "searching \(d)"
        case .delegating: return d.isEmpty ? "sending a helper…" : "helper: \(d)"
        case .waiting:    return waitingLine(d)
        case .idle, .done, .stopped, .error: return ""
        }
    }

    /// What she is blocked on. The hook sends either a word for the two tools that
    /// want an answer rather than a permission, a short verb phrase for a permission
    /// ("run the tests", "edit Brain.swift"), or a bare kind from a notification.
    private static func waitingLine(_ d: String) -> String {
        switch d {
        case "question":   return "has a question!"
        case "plan":       return "plan needs your ok!"
        case "plan first": return "wants to plan first, ok?"
        case "permission": return "needs your ok!"
        case "input":      return "needs your input!"
        default: break
        }
        for verb in ["run ", "use ", "edit ", "read ", "fetch ", "search ", "send a helper"]
            where d.hasPrefix(verb) { return "ok to \(d)?" }
        let low = d.lowercased()
        if low.contains("permission") || low.contains("permiso") || low.contains("approv") { return "needs your ok!" }
        if low.contains("waiting") || low.contains("input") { return "your turn!" }
        return d.isEmpty ? "needs you!" : d
    }

    var bounds: ClosedRange<CGFloat> = 0...1200

    /// Hidden QA mode: cycles every state on a fixed schedule.
    let demo = ProcessInfo.processInfo.environment["COMPA_DEMO"] != nil
    private var demoLook: CGFloat = 0

    init(startX: CGFloat, feed: ClaudeFeed = ClaudeProbe()) { claude = feed; x = startX; walkTarget = startX }

    /// How far a shoulder can turn before the hand disappears behind the hair (layered
    /// rig only; see the notes in docs/).
    static let armLimit: CGFloat = 32
    /// Rest angle of the rig's arms, which are drawn held out to the sides.
    static let armRest: CGFloat = 24

    /// Walk cadence, and how far one step actually carries a rig: the foot swings
    /// 2·r·sin(19°) with r the hip-to-sole distance. Deriving the speed from the
    /// stride is what stops the feet from skating, at any pet size.
    static let stepsPerSecond: CGFloat = 2.7
    static let strideCanonical: CGFloat = 2 * 254 * 0.3256   // sin 19°
    /// Canonical pixels to points; the app sets it from the rendered scale.
    var scale: CGFloat = 0.1427
    /// Canonical pixels per sprite cell in the rig's pixel build, 0 otherwise.
    var cell: CGFloat = 0
    private var walkSpeed: CGFloat { walkOverride ?? Brain.stepsPerSecond * Brain.strideCanonical * scale }

    func enter(_ a: Activity) {
        // a directed walk (coming in, leaving) is interrupted by nothing but the mouse
        if forced, activity == .walking, a != .dragged { return }
        if a == .dragged { forced = false; arrive = nil }
        guard activity != a else { return }
        blendFrom = lastPose        // ease out of whatever she was doing
        blendStart = t
        activity = a
        stateStarted = t
    }

    func wave() { enter(.waving) }

    // ---- one pet per session ----
    /// Places she goes to depending on what she does: her desk to work, a step forward
    /// when Claude waits on you, the sofa to sleep, the window to look out. Stage only;
    /// with no spots (the classic pet) nothing of this runs.
    struct Spots { var work: CGFloat?; var wait: CGFloat?; var rest: CGFloat?; var window: CGFloat? }
    var spots: Spots?
    private(set) var commuting = false
    private(set) var forced = false
    private var arrive: (() -> Void)?

    /// Walks to x, then calls `then`. May leave her bounds (coming in from outside,
    /// going out through the door).
    func walkTo(_ target: CGFloat, then: (() -> Void)? = nil) {
        forced = false
        enter(.walking)
        walkTarget = target; forced = true; arrive = then
        facing = target > x ? 1 : -1
    }

    /// The flock moves her itself (stage, window slots).
    func place(x newX: CGFloat) { x = newX }

    /// A click on her: whatever she was trying to tell you, you have seen it.
    /// A standing permission prompt stays up (only answering it clears that), but
    /// she stops insisting for a while.
    func acknowledge() {
        notices.removeAll()
        if claude.state == .waiting { nextNag = t + 90 }
    }

    /// Seen, for one session only (from the menu's session list).
    func acknowledge(session: String) { notices[session] = nil }

    /// The stretch she is watching stops counting, without a celebration (Claude
    /// Desktop taken off the list while it answers has not finished anything).
    func dropStretch() { land(celebrating: false) }

    func beginDrag() { enter(.dragged) }
    func endDrag(at newX: CGFloat) {
        x = newX; landedAt = t; enter(.idle); nextDecision = t + 2.5
    }

    private func rnd(_ a: CFTimeInterval, _ b: CFTimeInterval) -> CFTimeInterval {
        a + (b - a) * CFTimeInterval.random(in: 0...1)
    }

    func step(dt: CFTimeInterval, cursor: CGPoint, headPoint: CGPoint) -> PetFrame {
        t += dt
        // the full probe is expensive (every pid on the machine), the signal files are
        // not - and the cheap half is the one that has to keep up with her
        if t - claudeSampled > 1.5 {
            // the probe always gets the system clock: it keeps timestamps between calls
            // (when Claude Desktop got busy, when it last sampled), and the flock drives
            // the same probe with CACurrentMediaTime. Mixing this brain's own t (zero at
            // launch) with that left the Desktop guess stuck after switching modes.
            claude.refresh(now: CACurrentMediaTime()); claudeSampled = t; claudePolled = t
        } else if t - claudePolled > 0.2 {
            claude.poll(now: CACurrentMediaTime()); claudePolled = t
        }

        // this crosses into the window server, so it gets sampled a few times a second
        // and interpolated in between
        if t - idleSampled > 0.25 {
            idleAt = CGEventSource.secondsSinceLastEventType(.hidSystemState,
                                                            eventType: CGEventType(rawValue: ~0)!)
            idleSampled = t
        }
        let userIdle = idleAt + (t - idleSampled)

        react(now: t, userIdle: userIdle)
        for e in claude.takeEvents() { handle(e) }
        tendNotice(dt: dt, userIdle: userIdle)
        if demo { return frame(demoStep(dt: dt)) }

        if activity == .turning, !turned, t - stateStarted > 0.2 { facing = -facing; turned = true }

        switch activity {
        case .turning where t - stateStarted > 0.5: enter(.idle); nextDecision = t + rnd(3, 8)
        case .waving where t - stateStarted > 1.7: enter(.idle); nextDecision = t + rnd(3, 7)
        case .working where !claude.isBusy && t - stateStarted > 1.5: enter(.idle); nextDecision = t + rnd(2, 5)
        // after the party, back to work if another session is still going
        case .celebrating where t - stateStarted > 2.2:
            enter(watching && claude.isBusy ? .working : .idle); nextDecision = t + rnd(2, 5)
        case .failed where t - stateStarted > Brain.failedTime:
            enter(watching && claude.isBusy ? .working : .idle); nextDecision = t + rnd(2, 5)
        case .idle, .sleeping:
            if userIdle > 240 && !claude.isBusy && claude.state != .waiting { enter(.sleeping) }
            else if activity == .sleeping { enter(.idle); nextDecision = t + rnd(2, 6) }
        default: break
        }

        // Back at the machine with something pending: that is the moment to make
        // sure you see it, not the moment it happened while you were away.
        if userIdle > 30 { wasAway = true }
        else if wasAway, userIdle < 1 {
            wasAway = false
            if reactsToClaude, notice != nil || claude.state == .waiting,
               activity == .idle || activity == .sleeping { enter(.waving) }
        }

        if activity == .idle && t > nextDecision {
            if wanders && Bool.random() {
                if let w = spots?.window, Double.random(in: 0...1) < 0.3 {
                    walkTarget = w + CGFloat.random(in: -12...12)     // to look out of the window
                } else {
                    walkTarget = CGFloat.random(in: bounds)
                }
                if abs(walkTarget - x) > 60 { enter(.walking) } else { nextDecision = t + rnd(4, 9) }
            } else if Bool.random() {
                turned = false
                enter(.turning)
            } else {
                nextDecision = t + rnd(4, 9)
            }
        }

        if activity == .walking {
            let dir: CGFloat = walkTarget > x ? 1 : -1
            facing = dir
            x += dir * walkSpeed * CGFloat(dt)
            let arrived = abs(walkTarget - x) < (forced ? 2 : 8)
            let out = !forced && !bounds.contains(x)
            if arrived || out {
                let wasForced = forced
                forced = false
                if wasForced { x = walkTarget } else { x = min(max(x, bounds.lowerBound), bounds.upperBound) }
                enter(.idle); nextDecision = t + rnd(4, 10)
                if let f = arrive { arrive = nil; f() }
            }
        }
        // to her spot: the desk to work, a step forward when you are needed, the sofa to sleep
        commuting = false
        if let sp = spots, activity != .walking, activity != .dragged {
            var spot: CGFloat?
            if activity == .working { spot = sp.work }
            else if activity == .sleeping { spot = sp.rest }
            else if reactsToClaude, claude.state == .waiting, activity == .idle || activity == .waving { spot = sp.wait }
            if let s = spot, abs(s - x) > 0.5 {
                let dir: CGFloat = s > x ? 1 : -1
                facing = dir
                x += dir * min(abs(s - x), walkSpeed * CGFloat(dt))
                commuting = true
            }
        }
        if activity != .dragged, !forced, !commuting, !bounds.contains(x) {
            x = min(max(x, bounds.lowerBound), bounds.upperBound)
        }

        // ---- gaze target ----
        var target = cursor
        if reactsToClaude, claude.isFrontmost, userIdle > 3, let c = claude.windowCenter { target = c }
        if activity == .sleeping { target = CGPoint(x: headPoint.x, y: headPoint.y - 200) }
        let dx = (target.x - headPoint.x) / 420
        let dy = (headPoint.y - target.y) / 320
        let wantX = followsCursor ? max(-1, min(1, dx)) : 0
        let wantY = followsCursor ? max(-1, min(1, dy)) : 0
        let k = CGFloat(min(1, dt * 6))
        lookX += (wantX - lookX) * k
        lookY += (wantY - lookY) * k

        // atlas v2: one of 16 directions, clockwise from up, with a dead zone around
        // her so she looks ahead when the cursor is on her (and a little hysteresis so
        // she doesn't flicker at its edge)
        var newLook: Int?
        if hasLook, followsCursor, activity == .idle, currentClip() == .idle {
            let vx = target.x - headPoint.x, vy = target.y - headPoint.y
            if hypot(vx, vy) > (look == nil ? 120 : 90) {
                var deg = atan2(vx, vy) * 180 / .pi
                if deg < 0 { deg += 360 }
                newLook = Int((deg / 22.5).rounded()) % 16
            }
        }
        look = newLook

        return frame(settled(pose(userIdle: userIdle)))
    }

    /// Wraps the pose with the atlas-side choices and refreshes the balloon.
    private func frame(_ pose: Pose) -> PetFrame {
        let c = currentClip()
        if c != clip { clip = c; clipStarted = t }
        updateBalloon()
        return PetFrame(pose: pose, clip: clip, clipAge: t - clipStarted, look: look,
                        sleeping: activity == .sleeping)
    }

    /// Which atlas row fits what she is doing.
    private func currentClip() -> SpriteClip {
        if commuting { return facing > 0 ? .runRight : .runLeft }
        // not while working: the line changes with every tool call, and each one would
        // cut the work loop (and replay its intro) to move the mouth
        if hasTalk, t < talkUntil, activity == .idle || activity == .turning {
            return .talking
        }
        if activity != .walking, let c = reactionClips[activity] { return c }
        switch activity {
        case .walking:      return facing > 0 ? .runRight : .runLeft
        case .waving:       return .waving
        case .celebrating:  return .jumping
        case .dragged:      return .jumping
        case .failed:       return .failed
        case .working:      return claude.state == .reading || claude.state == .searching ? .review : .working
        case .idle, .turning, .sleeping:
            return reactsToClaude && claude.state == .waiting ? .waiting : .idle
        }
    }

    /// Everything Claude does, turned into something she does. This is the level
    /// side: what is going on right now. Notices come from `handle`.
    ///
    /// `lastState` advances whether or not she is allowed to react, so a switch flipped
    /// in the middle of an answer can't strand her, and can't make her celebrate one
    /// she never saw start.
    private func react(now t: CFTimeInterval, userIdle: CFTimeInterval) {
        let st = claude.state
        if watching, claude.isSignalled { stretchSignalled = true }
        guard let previous = lastState else { lastState = st; return }
        lastState = st
        if st != previous { stateChangedAt = t }
        if st.isWorking, st != .thinking { sawTool = true }
        // a drag is the one thing that outranks Claude - the mouse owns her then - but
        // it only pauses her reactions; turning the switch off ends them
        let allowed = reactsToClaude && activity != .dragged
        if watching, !reactsToClaude { land(celebrating: false) }

        if st.isWorking {
            // `!watching`, not `st != previous`: she joins an answer that was already
            // running when she looked - at launch, after a drag - instead of sitting
            // out the whole turn because she never saw it start.
            if !watching, allowed {
                busyStarted = t
                watching = true
                stretchSignalled = claude.isSignalled
                sawTool = st != .thinking
                opener = say("start", Self.startLines)
                enter(.working)
            } else if st != previous, watching, allowed, activity != .celebrating, activity != .failed {
                enter(.working)
            }
            // Back to work after anything that interrupted it - being carried, a click,
            // a wave - while the same work went on. Without this she stood idle under
            // a "thinking…" balloon until Claude happened to change state.
            if watching, allowed, activity == .idle { enter(.working) }
        } else if st == .waiting {
            // blocked on you: she waves, then holds the waiting pose with the orange
            // balloon up for as long as the prompt stands
            if allowed, !watching || st != previous {
                watching = true; enter(.waving); nextNag = t + 5; waitingSince = t
            }
        } else if st != previous {
            switch st {
            case .done, .stopped, .error:
                // the event brings the celebration or the slump (it is noticed even
                // when this frame-level edge was missed); here the stretch just ends
                land(celebrating: false)
            default:
                // the CPU guess went quiet (Claude Desktop), or a report vanished. A
                // blip is not an answer: on the guess she must have been busy for a
                // while, and a report only ends in a party through a real `done`.
                land(celebrating: watching && allowed && !claude.isSignalled
                                  && !stretchSignalled
                                  && previous != .waiting
                                  && t - busyStarted > Brain.guessedAnswer,
                     guessed: true)
            }
        }

        // Insisting on a prompt: every 5 s for the first 20, then only while you are
        // at the machine, every 40 s. Waving at an empty chair is noise; waving at
        // someone who has been typing in another window for ten minutes is the point.
        if st == .waiting, watching, allowed, t > nextNag,
           activity == .idle || activity == .waving {
            let early = t - waitingSince < 20
            if early || userIdle < 10 {
                nextNag = t + (early ? 5 : 40)
                enter(.waving)
            }
        }

        guard watching else { workLine = ""; return }
        // A bare `thinking` right after a tool: the model is reading what the tool
        // returned, and the next tool is often a second away. Hold the tool line.
        let bareThinking = st == .thinking && claude.detail.trimmingCharacters(in: .whitespaces).isEmpty
        if bareThinking, sawTool, !workLine.isEmpty, t - stateChangedAt < Self.toolLineGrace { return }
        let starter = claude.isSignalled && !sawTool ? opener : "thinking…"
        workLine = Self.line(for: st, detail: claude.detail, opener: starter)
    }

    /// The edge side: things that happened, noticed however late.
    private func handle(_ e: ClaudeEvent) {
        switch e.kind {
        case .finished:
            guard reactsToClaude else { return }
            let n = Notice(kind: .done, session: e.session, project: e.project,
                           text: say("done", Self.doneLines))
            post(n)
            if busyElsewhere {
                if !e.quiet { flash = (text: n.text, tone: BubbleTone.done, tag: n.project); flashUntil = t + 3.5 }
            } else {
                // the last one: the summary of all of them beats a lone flash from a moment ago
                flash = nil
                if activity != .dragged, !e.quiet { enter(.celebrating) }
            }
            if !e.quiet { alert?(e) }
        case .failed:
            guard reactsToClaude else { return }
            let d = e.detail.trimmingCharacters(in: .whitespaces)
            let n = Notice(kind: .error, session: e.session, project: e.project,
                           text: d.isEmpty || d == "api" ? say("error", ["something went wrong"]) : d)
            post(n)
            if busyElsewhere {
                if !e.quiet { flash = (text: n.text, tone: BubbleTone.error, tag: n.project); flashUntil = t + 4 }
            } else {
                flash = nil
                if activity != .dragged, !e.quiet { enter(.failed) }
            }
            if !e.quiet { alert?(e) }
        case .needsYou:
            guard reactsToClaude else { return }
            if !e.quiet { alert?(e) }
        case .engaged, .gone:
            // a new turn in that session (or its end) means you are on it
            notices[e.session] = nil
        }
    }

    /// Ages the notices, but only while you are around.
    private func tendNotice(dt: CFTimeInterval, userIdle: CFTimeInterval) {
        guard !notices.isEmpty else { return }
        if !reactsToClaude { notices.removeAll(); return }
        guard userIdle < 5 else { return }
        for k in Array(notices.keys) {
            guard var n = notices[k] else { continue }
            n.seenFor += dt
            notices[k] = n.seenFor > Self.noticeLife ? nil : n
        }
    }

    /// The stretch of work she was watching is over.
    private func land(celebrating: Bool, guessed: Bool = false) {
        if celebrating {
            enter(.celebrating)
            if guessed {
                // Claude Desktop has no hook: the guess is all there is, and it gets
                // the same sticky notice a hook's `done` gets
                let e = ClaudeEvent(kind: .finished, session: "desktop", project: "Claude Desktop", detail: "", quiet: false)
                post(Notice(kind: .done, session: e.session, project: e.project,
                             text: say("done", Self.doneLines)))
                alert?(e)
            }
        }
        watching = false
        workLine = ""
    }

    /// "mi-app, api" for the notices, newest first, each project once, the rest
    /// counted past three.
    static func projectList(_ notices: [String: Notice]) -> String {
        var seen = Set<String>()
        let names = notices.values.sorted { $0.order > $1.order }
            .map { $0.project }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        if names.count <= 3 { return names.joined(separator: ", ") }
        return names.prefix(2).joined(separator: ", ") + " +\(names.count - 2)"
    }

    /// One place decides what the balloon says, by priority: a prompt waiting on you,
    /// then the work in progress, then an unseen notice.
    private func updateBalloon() {
        // a pet of ONE session carries the project on its label: the balloon leaves it out
        let single = claude.key != nil
        var want: (text: String, tone: BubbleTone, tag: String)?
        if announces, reactsToClaude {
            let live = claude.sessions.filter { $0.state.isWorking || $0.state == .waiting }
            if claude.state == .waiting, watching, !workLine.isEmpty {
                // "mi-app +1": another session is queued up behind this prompt
                let others = claude.sessions.filter { $0.state == .waiting }.count - 1
                let tag = single ? "" : claude.project + (others > 0 ? " +\(others)" : "")
                want = (text: workLine, tone: BubbleTone.waiting, tag: tag)
            } else if let f = flash, t < flashUntil {
                // a session finished while others work: say it, then back to the work line
                want = (text: f.text, tone: f.tone, tag: single ? "" : f.tag)
            } else if watching, !workLine.isEmpty, claude.state != .waiting {
                // with one session the project is obvious; with several it is the point
                want = (text: workLine, tone: BubbleTone.working, tag: live.count > 1 ? claude.project : "")
            } else if let n = notice {
                let tone: BubbleTone = notices.values.contains { $0.kind == .error } ? .error : .done
                want = (text: n.text, tone: tone, tag: single ? "" : Self.projectList(notices))
            }
        }
        guard let w = want else {
            if !lastLine.isEmpty { lastLine = ""; hush?() }
            return
        }
        if w.text != lastLine || w.tone != lastTone || w.tag != lastTag {
            lastLine = w.text; lastTone = w.tone; lastTag = w.tag
            speak?(w.text, .infinity, w.tone, w.tag)
            talkUntil = t + min(2.6, max(0.8, Double(w.text.count) * 0.07))
        }
    }

    private func demoStep(dt: CFTimeInterval) -> Pose {
        runDemoScript()
        let k = CGFloat(min(1, dt * 6))
        lookX += (demoLook - lookX) * k
        lookY += (0 - lookY) * k
        return settled(pose(userIdle: 0))
    }

    /// Eases the first fraction of a second after a state change, then gets out of the
    /// way: the blend only runs against the pose she was frozen at.
    private func settled(_ p: Pose) -> Pose {
        var out = p
        if let from = blendFrom {
            let k = CGFloat((t - blendStart) / blendTime)
            if k >= 1 { blendFrom = nil }
            else { out = Pose.mix(from, p, k*k*(3 - 2*k)) }   // smoothstep
        }
        lastPose = out
        return out
    }

    /// 24-second loop through every state, for reviewing the animation.
    private func runDemoScript() {
        let phase = t.truncatingRemainder(dividingBy: 24)
        demoLook = 0
        switch phase {
        case 0..<3:   enter(.idle)
        case 3..<5:   enter(.idle); demoLook = 1
        case 5..<7:   enter(.idle); demoLook = -1
        case 7..<9:   enter(.waving)
        case 9..<13:  enter(.walking); facing = phase < 11 ? 1 : -1
        case 13..<15: enter(.working)
        case 15..<18: enter(.celebrating)
        case 18..<21: enter(.failed)
        default:      enter(.sleeping)
        }
    }

    private func pose(userIdle: CFTimeInterval) -> Pose {
        var p = Pose()
        p.facing = facing
        let age = t - stateStarted

        switch activity {
        case .idle, .dragged:
            let br = sin(t * 2 * .pi / 3.4)
            p.bodyScaleY = 1 + 0.014*br; p.bodyScaleX = 1 - 0.011*br
            p.bodyDY = -1.8*br
            p.headDY = -0.7*br
            // breathing is 1.8 canonical pixels - a fifteenth of a cell, which rounds
            // to nothing on the sprite grid and leaves her standing dead still. In
            // pixel mode it becomes what a pixel-art idle actually is: one whole pixel
            // up, one down.
            if cell > 0 { p.rootDY = br > 0.25 ? -cell : 0 }
            p.armLRot = Brain.armRest + 1.6*sin(t * 2 * .pi / 3.4 + 0.4)
            p.armRRot = -Brain.armRest - 1.6*sin(t * 2 * .pi / 3.4 + 0.7)
            if activity == .dragged {
                p.armLRot = -22; p.armRRot = 22
                p.legLRot = -7; p.legRRot = 6
                p.headRot = 3*sin(t*4)
            }

        case .turning:
            // a hop on the spot, mirrored at the top of it
            let k = min(1, age/0.5)
            let air = sin(k * .pi)
            p.rootDY = cell > 0 ? (air > 0.5 ? -cell : 0) : -18*air
            p.armLRot = Brain.armRest - 6*air; p.armRRot = -Brain.armRest + 6*air
            p.shadowScale = 1 - 0.2*air
            p.shadowOpacity = 1 - 0.3*air

        case .walking:
            let ph = t * 2 * .pi * Brain.stepsPerSecond/2
            p.legLRot = 19*sin(ph); p.legRRot = 19*sin(ph + .pi)
            p.armLRot = Brain.armRest - 11*sin(ph); p.armRRot = -Brain.armRest + 11*sin(ph)
            // the bob has to live in rootDY: bodyDY moves the torso a fraction of a
            // point at pet size, which is why the old walk looked like a glide
            p.rootDY = -13*abs(sin(ph))
            p.bodyRot = 1.4*sin(ph)
            p.headRot = -1.0*sin(ph)
            p.headDY = 2.0*abs(sin(ph))
            if cell > 0 { p.rootDY = abs(sin(ph)) > 0.5 ? -cell : 0; p.headDY = 0 }
            p.shadowScale = 0.94 - 0.06*abs(sin(ph))
            p.shadowOpacity = 1 - 0.12*abs(sin(ph))

        case .waving:
            let e = min(1, age/0.22) * min(1, max(0, (1.7 - age)/0.28))
            // 22±8 keeps the hand clear of her hair; 42±15 hid it and left a stump
            p.armRRot = e * (22 + 8*sin(age * 2 * .pi * 3.1))
            p.armLRot = Brain.armRest
            p.headRot = e * 4
            p.rootDY = -7*abs(sin(age * 2 * .pi * 1.55))
            p.bodyRot = e * 2.2*sin(age * 2 * .pi * 3.1)
            p.bodyScaleY = 1 + 0.02*sin(age * 2 * .pi * 3.1)
            if cell > 0 { p.rootDY = abs(sin(age * 2 * .pi * 1.55)) > 0.5 ? -cell : 0 }

        case .working:
            let ph = t * 2 * .pi * 0.85
            p.bodyDY = -2.4*abs(sin(ph))
            p.bodyScaleY = 1 + 0.02*sin(ph); p.bodyScaleX = 1 - 0.016*sin(ph)
            p.headDY = 1.2 - 1.6*abs(sin(ph))
            p.headRot = 2.2*sin(ph/2)
            p.armLRot = Brain.armRest + 4*sin(ph); p.armRRot = -Brain.armRest - 4*sin(ph)
            p.legLRot = 1.5*sin(ph)
            if cell > 0 {
                // A calm, slow bob of one pixel. What tells you she is working is the
                // balloon, which stays up for the whole answer - the body language only
                // has to be different from idle, not busier than it.
                let b = abs(sin(ph))
                p.rootDY = b > 0.55 ? -cell : 0
                p.headDY = b > 0.85 ? cell : 0
                // baked angles are 8 apart, so 9±4 never left the first bucket and she
                // looked exactly like idle; 14±8 reaches the next two.
                p.armLRot = Brain.armRest + 8*sin(ph); p.armRRot = -Brain.armRest - 8*sin(ph)
            }

        case .celebrating:
            // three little hops with both arms up - deliberately unlike anything else
            // she does, so it reads as an event and not as her idle fidgeting
            // crouch first, then three hops with the hands shaking overhead. The phase
            // is cut at a whole number of hops so the state ends with both feet on the
            // floor instead of mid-air.
            let anticip = 0.18, hz = 1.15        // two unhurried hops, not three quick ones
            let hopEnd = anticip + 2/hz
            let ph = (age - anticip) * 2 * .pi * hz
            let hopping = age > anticip && age < hopEnd
            let air = hopping ? max(0, sin(ph)) : 0
            let squash = age < anticip ? sin(age/anticip * .pi)
                                       : (hopping ? max(0, -sin(ph)) : 0)
            p.rootDY = -118*air
            p.bodyScaleY = 1 + 0.045*air - 0.085*squash
            p.bodyScaleX = 1 - 0.035*air + 0.065*squash
            p.bodyDY = 7*squash
            p.bodyRot = 2.4*sin(age * 2 * .pi * 0.75)
            p.headDY = -3*air + 4*squash
            p.headRot = 4.5*sin(age * 2 * .pi * 0.75 + 0.5)
            let arms = 24 + 8*sin(age * 2 * .pi * 3)          // manitos al aire
            p.armLRot = -arms; p.armRRot = arms
            p.legLRot = -9*air; p.legRRot = 9*air
            p.shadowScale = 1 - 0.28*air
            p.shadowOpacity = 1 - 0.42*air
            if cell > 0 {                       // the hop is already several cells
                p.bodyDY = squash > 0.45 ? cell : 0
                p.headDY = squash > 0.45 ? cell : 0
            }

        case .failed:
            // deflates: head drops, body sags a little, arms hang. Short, and nothing
            // like the celebration, so a red balloon and a slump read together.
            let k = CGFloat(min(1, age/0.3)) * CGFloat(min(1, max(0, (Brain.failedTime - age)/0.3)))
            p.headRot = -6*k; p.headDY = 4.5*k; p.headDX = -1.5*k
            p.bodyScaleY = 1 - 0.035*k; p.bodyScaleX = 1 + 0.02*k; p.bodyDY = 3*k
            p.armLRot = Brain.armRest + 3*k; p.armRRot = -Brain.armRest - 3*k
            if cell > 0 { p.headDY = k > 0.5 ? cell : 0; p.bodyDY = 0 }

        case .sleeping:
            let br = sin(t * 2 * .pi / 5.0)
            p.bodyScaleY = 1 + 0.022*br; p.bodyScaleX = 1 - 0.018*br
            p.bodyDY = 5 - 2.4*br
            p.headRot = -7; p.headDY = 5.5 - 1.2*br; p.headDX = -2
            p.armLRot = Brain.armRest; p.armRRot = -Brain.armRest
            p.lidOpacity = 1
            if cell > 0 {                       // slumped, breathing one pixel
                p.headDY = cell
                p.bodyDY = 0
                p.rootDY = br > 0 ? 0 : -cell
            }
        }

        // landing squash after a drag
        let sinceLand = t - landedAt
        if sinceLand < 0.34 {
            let q = 1 - sinceLand/0.34
            p.bodyScaleY *= 1 - 0.13*q*q
            p.bodyScaleX *= 1 + 0.10*q*q
            p.headDY += 5*q*q
        }

        // ---- gaze, layered on top of whatever she is doing ----
        let lx = lookX * facing        // her own left/right once mirrored
        if activity != .sleeping {
            if cell > 0 {
                // three gaze positions instead of a slide: left, centre, right. The
                // head only joins in at the extremes, so it reads as a glance and not
                // as the whole head sliding across the sprite.
                p.irisDX = abs(lx) > 0.3 ? (lx > 0 ? cell : -cell) : 0
                p.irisDY = abs(lookY) > 0.45 ? (lookY > 0 ? -cell : cell) : 0
                p.headDX = abs(lx) > 0.75 ? (lx > 0 ? cell : -cell) : 0
            } else {
                p.headDX += 4.0*lx
                p.headRot += -3.2*lx
                p.headSquashX = 1 - 0.05*abs(lx)
                p.headDY += -2.4*lookY
                p.irisDX = 4.2*lx
                p.irisDY = -3.2*lookY
            }
        }

        // ---- blinking ----
        if activity != .sleeping {
            if t > nextBlink {
                blinkStart = t
                // every so often she blinks twice, which is what makes it read as a
                // blink rather than as a dropped frame
                doubleBlink = Double.random(in: 0...1) < 0.5
                nextBlink = t + rnd(2.0, 4.5)
            }
            let b = t - blinkStart
            if cell > 0 {
                // hard on and off. A 1-bit sprite drawn at half opacity is a smudge
                // over her eyes, not a blink - which is why it never read as one.
                p.lidOpacity = (b < 0.28 || (doubleBlink && b > 0.42 && b < 0.68)) ? 1 : 0
            } else if b < 0.15 {
                p.lidOpacity = b < 0.05 ? b/0.05 : (b < 0.10 ? 1 : (0.15 - b)/0.05)
            }
        }

        lidNow = p.lidOpacity
        p.shadowOpacity = activity == .sleeping ? 1.05 : p.shadowOpacity

        // hard stop, so no future tweak can send a hand behind her hair again
        p.armLRot = min(max(p.armLRot, -Brain.armLimit), Brain.armLimit)
        p.armRRot = min(max(p.armRRot, -Brain.armLimit), Brain.armLimit)
        return p
    }
}
