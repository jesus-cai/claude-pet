import AppKit

/// Settings of the one-pet-per-session mode, read from the defaults by the app.
struct FlockSettings {
    var by: Assign.By = .mix
    var layout = "stage"                 // stage | walks | free
    var scene = "oficina"
    var stageSize: CGFloat = 2
    var rotation: [String] = []          // empty = every pet
    var pins: [String: Assign.Pin] = [:]
    var mainPet = "mochi"
    var petHeight: CGFloat = 150
    var stageOrigin: CGPoint?
    var wanders = true, followsCursor = true, reactsToClaude = true, announces = true
    /// The stage hides itself while no session is open.
    var hideEmptyStage = false
}

/// One pet of the flock: its session's feed, its brain, its look, and where it is drawn.
final class FlockMember {
    let key: String
    let feed: ClaudeFeed
    let brain: Brain
    var petId: String, color: Int, tint: Bool, label: String
    var entry: PetEntry
    /// Whatever draws her: a SpriteView for an atlas pet, a PetView for a layered rig
    /// (Chihiro). In a window it is the window's content; in the stage its layer is
    /// hung straight into the stage's layer tree.
    var canvas: PetCanvas?
    let bubble = Bubble()
    let tag = Tag()
    var leaving = false
    var dragging = false
    // its own little window (walks, free)
    var window: PetWindow?
    var home: CGFloat = 0
    var floorY: CGFloat = 0
    // inside the stage
    var desk: CGFloat?

    init(key: String, feed: ClaudeFeed, brain: Brain, a: Assign.Result, entry: PetEntry) {
        self.key = key; self.feed = feed; self.brain = brain
        petId = a.pet; color = a.color; tint = a.tint; label = a.label
        self.entry = entry
    }

    var nsColor: NSColor { Assign.palette[color % Assign.palette.count].ns }
    var isRig: Bool { if case .rig = entry.kind { return true }; return false }
}

/// Lets a pet window catch the mouse only over the pet's own pixels.
final class FlockHost: NSView {
    weak var canvas: PetCanvas?
    var down: ((NSEvent) -> Void)?, dragged: ((NSEvent) -> Void)?, up: ((NSEvent) -> Void)?
    var right: ((NSEvent) -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let c = canvas else { return nil }
        return c.hitsPet(c.convert(point, from: superview)) ? self : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { down?(e) }
    override func mouseDragged(with e: NSEvent) { dragged?(e) }
    override func mouseUp(with e: NSEvent) { up?(e) }
    override func rightMouseDown(with e: NSEvent) { right?(e) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

/// The one-pet-per-session mode. One probe, one clock, a brain per session. The
/// classic single pet never comes through here.
final class Flock {
    let probe: ClaudeProbe
    var settings: FlockSettings
    let catalog: () -> [PetEntry]
    let alert: (ClaudeEvent) -> Void
    var onStageMoved: (CGPoint) -> Void = { _ in }
    var onRightClick: (NSEvent, NSView) -> Void = { _, _ in }

    private(set) var members: [String: FlockMember] = [:]
    private var order: [String] = []
    private var assigned: [String: Assign.Result] = [:]
    private var stageWindow: PetWindow?
    private var stageView: StageView?
    private var lastRefresh: CFTimeInterval = -10, lastPoll: CFTimeInterval = -10, lastSync: CFTimeInterval = -10
    private static let maxPets = 6

    init(probe: ClaudeProbe, settings: FlockSettings, catalog: @escaping () -> [PetEntry],
         alert: @escaping (ClaudeEvent) -> Void) {
        self.probe = probe; self.settings = settings; self.catalog = catalog; self.alert = alert
    }

    // ---------- for the app ----------
    func resetAssignments() { assigned = [:] }
    func forgetSheets() {}     // views are built fresh per pet: nothing cached to forget

    /// Unseen notices of every pet, by session (menu and menu bar dot).
    func notices() -> [String: Brain.Notice] {
        var all: [String: Brain.Notice] = [:]
        for m in members.values { for (k, n) in m.brain.notices { all[k] = n } }
        return all
    }
    func acknowledge(_ key: String? = nil) {
        for m in members.values where key == nil || m.key == key { m.brain.acknowledge() }
    }
    func wave() { for m in members.values { m.brain.wave() } }

    /// The rescue item: the stage to the middle of the main screen; pets in windows home
    /// around the middle.
    func recenter() {
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        if let w = stageWindow {
            let o = CGPoint(x: (vf.midX - w.frame.width / 2).rounded(), y: vf.minY + 30)
            w.setFrameOrigin(o); w.orderFrontRegardless()
            settings.stageOrigin = o; onStageMoved(o)
            return
        }
        let live = order.compactMap { members[$0] }.filter { !$0.leaving }
        for (i, m) in live.enumerated() {
            let step = max(90, (m.canvas?.bounds.width ?? 120) * 0.9)
            m.home = vf.midX + (CGFloat(i) - CGFloat(live.count - 1) / 2) * step
            m.floorY = vf.minY + 22
            m.brain.walkTo(m.home)
        }
    }

    /// One line for COMPA_DEBUG: what the probe sees and what each pet does.
    func debugLine() -> String {
        let pets = order.compactMap { members[$0] }.map { (m: FlockMember) -> String in
            // filas+N: rows of her atlas drawn smaller than the idle one, blown up to it
            let grown = (m.canvas as? SpriteView)?.sheet.scaledRows ?? 0
            return "\(m.label)=\(m.brain.activity)/\(m.feed.state.rawValue)/h\(Int(m.canvas?.headHeight ?? 0))/filas+\(grown)"
        }.joined(separator: " ")
        let density = stageWindow?.screen.map { "\(Int($0.backingScaleFactor))x" } ?? "?"
        return "multi layout=\(settings.layout) zoom=\(settings.stageSize) petHeight=\(settings.petHeight) screen=\(density) "
            + "stage=\(stageWindow.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "-") "
            + "desktop(open=\(probe.desktopRunning) busy=\(probe.desktopBusy) front=\(probe.isFrontmost) "
            + "cpu=\(String(format: "%.2f", probe.cpu)) guessing=\(probe.keepsGuessing)) "
            + "sessions=\(probe.sessions.count) claudeCode[\(probe.presence.values.map { $0.status }.joined(separator: ","))] "
            + "pets[\(pets)]"
    }
    func applySwitches() {
        for m in members.values {
            m.brain.wanders = settings.wanders; m.brain.followsCursor = settings.followsCursor
            m.brain.reactsToClaude = settings.reactsToClaude; m.brain.announces = settings.announces
        }
    }

    func start() {
        stop()
        probe.keepsGuessing = true
        if settings.layout == "stage" { openStage() }
    }

    func stop() {
        probe.keepsGuessing = false
        for m in members.values { remove(m) }
        members = [:]; order = []
        stageWindow?.orderOut(nil); stageWindow?.close(); stageWindow = nil; stageView = nil
    }

    // ---------- who is here ----------
    /// Every pet can join, atlas or layered rig.
    private func petIDs() -> [String] { catalog().map { $0.id } }

    private func entry(_ id: String) -> PetEntry? { catalog().first { $0.id == id } }

    /// A fresh view for one member (each needs her own: a view draws one pet).
    private func makeCanvas(_ m: FlockMember, height: CGFloat, backing given: CGFloat? = nil) -> PetCanvas? {
        let backing = given ?? (NSScreen.main ?? NSScreen.screens[0]).backingScaleFactor
        guard let c = PetLibrary.makeCanvas(m.entry, petHeight: height, backing: backing,
                                            preferPixels: UserDefaults.standard.object(forKey: "pixels") as? Bool ?? true)
        else { return nil }
        // a rig cannot be recoloured layer by layer; its tag and shadow tell it apart
        (c as? SpriteView)?.tint = m.tint ? m.nsColor : nil
        m.brain.scale = c.rigScale
        m.brain.cell = c.rigCell
        if let s = c as? SpriteView {
            m.brain.hasTalk = s.sheet.rows[.talking] != nil
            m.brain.hasLook = settings.layout != "stage" && s.sheet.look.count == 16
        } else {
            m.brain.hasTalk = false; m.brain.hasLook = false
        }
        return c
    }

    private func sync() {
        var live = probe.sessions.map { (key: $0.key, project: $0.project) }
        // Claude Desktop has its own pet while it is open
        if probe.desktopRunning, !probe.isHidden("desktop") { live.append((key: "desktop", project: "Claude Desktop")) }
        for s in live where !order.contains(s.key) { order.append(s.key) }
        order = order.filter { k in live.contains { $0.key == k } || members[k] != nil }
        let want = Array(order.compactMap { k in live.first { $0.key == k } }.prefix(Self.maxPets))
        let ids = petIDs()
        guard !ids.isEmpty else { return }
        var rotation = settings.rotation.filter { ids.contains($0) }
        if rotation.isEmpty { rotation = ids }
        let main = ids.contains(settings.mainPet) ? settings.mainPet : ids[0]
        assigned = Assign.assign(want, by: settings.by, rotation: rotation, mainPet: main,
                                 pins: settings.pins, keep: assigned)
        for s in want {
            guard let a = assigned[s.key] else { continue }
            if let m = members[s.key] {
                if m.petId != a.pet || m.color != a.color || m.tint != a.tint || m.label != a.label { restyle(m, a) }
            } else {
                add(s.key, a)
            }
        }
        for m in members.values where !m.leaving && !want.contains(where: { $0.key == m.key }) { leave(m) }
    }

    private func add(_ key: String, _ a: Assign.Result) {
        guard members[key] == nil, let e = entry(a.pet) else { return }
        let feed: ClaudeFeed = key == "desktop" ? DesktopFeed(probe: probe) : SessionFeed(probe: probe, key: key)
        let brain = Brain(startX: 0, feed: feed)
        let m = FlockMember(key: key, feed: feed, brain: brain, a: a, entry: e)
        brain.wanders = settings.wanders; brain.followsCursor = settings.followsCursor
        brain.reactsToClaude = settings.reactsToClaude; brain.announces = settings.announces
        brain.alert = { [weak self] e in self?.alert(e) }
        brain.speak = { [weak m] text, secs, tone, tag in
            m?.bubble.say(text, seconds: secs, tone: tone, tag: tag, now: CACurrentMediaTime())
        }
        brain.hush = { [weak m] in m?.bubble.hush(now: CACurrentMediaTime()) }
        brain.setPersonality(reactions: m.entry.reactions, lines: m.entry.lines)
        members[key] = m
        m.tag.set(m.label, color: m.nsColor)
        if settings.layout == "stage", let sv = stageView { placeInStage(m, sv) } else { openWindow(m) }
        if m.canvas == nil { remove(m); members[key] = nil }     // her files did not load
    }

    private func restyle(_ m: FlockMember, _ a: Assign.Result) {
        let newPet = m.petId != a.pet
        if newPet, let e = entry(a.pet) {
            m.entry = e
            m.brain.setPersonality(reactions: e.reactions, lines: e.lines)
        }
        m.petId = a.pet; m.color = a.color; m.tint = a.tint; m.label = a.label
        m.tag.set(m.label, color: m.nsColor)
        if newPet {
            if let w = m.window, let host = w.contentView as? FlockHost, let c = makeCanvas(m, height: windowHeight) {
                host.subviews.forEach { $0.removeFromSuperview() }
                host.frame = c.bounds; host.addSubview(c); host.canvas = c
                w.setContentSize(c.bounds.size)
                m.canvas = c
            } else if let sv = stageView, let c = stageCanvas(m, sv) {
                m.canvas?.layer?.removeFromSuperlayer()
                m.canvas = c
                hang(c, in: sv)
            }
        } else {
            (m.canvas as? SpriteView)?.tint = m.tint ? m.nsColor : nil
        }
    }

    private func remove(_ m: FlockMember) {
        m.window?.orderOut(nil); m.window?.close(); m.window = nil
        if stageView != nil { m.canvas?.layer?.removeFromSuperlayer() }
        m.canvas = nil
        m.bubble.close(); m.tag.close()
    }

    private func leave(_ m: FlockMember) {
        m.leaving = true
        m.brain.wave()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak m] in
            guard let self, let m, self.members[m.key] != nil else { return }
            let done: () -> Void = { [weak self, weak m] in
                guard let self, let m else { return }
                self.remove(m)
                self.members[m.key] = nil
                self.order.removeAll { $0 == m.key }
            }
            if let sv = self.stageView { m.brain.walkTo(sv.scene.door, then: done) }
            else {
                let vf = AppDelegate.screen(nearest: CGPoint(x: m.brain.x, y: m.floorY)).visibleFrame
                m.brain.walkTo(m.brain.x > vf.midX ? vf.maxX + 120 : vf.minX - 120, then: done)
            }
        }
    }

    // ---------- little windows (walks, free) ----------
    private var windowHeight: CGFloat { settings.petHeight * 0.85 }

    private func openWindow(_ m: FlockMember) {
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        guard let v = makeCanvas(m, height: windowHeight) else { return }
        m.canvas = v
        // an atlas walks at a fixed pace; a rig's pace comes from its stride
        m.brain.walkOverride = v.walkSpeed
        let host = FlockHost(frame: v.bounds)
        host.addSubview(v); host.canvas = v
        let w = PetWindow(contentRect: v.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false; w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false; w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.contentView = host
        m.window = w
        m.floorY = vf.minY + 22            // room for the tag under the feet
        let i = CGFloat(members.values.filter { !$0.leaving }.count - 1)
        if settings.layout == "free" { m.home = CGFloat.random(in: (vf.minX + 120)...(vf.maxX - 120)) }
        else { m.home = vf.maxX - 120 - i * max(90, v.bounds.width * 0.9) }
        let fromRight = m.home > vf.midX
        m.brain.place(x: fromRight ? vf.maxX + 80 : vf.minX - 80)
        m.brain.walkTo(m.home)
        wire(m, host)
        w.orderFrontRegardless()
    }

    private func wire(_ m: FlockMember, _ host: FlockHost) {
        var start: CGPoint?, origin = CGPoint.zero, offsetY: CGFloat = 0, moved = false
        host.down = { [weak m] _ in
            guard let m, let w = m.window else { return }
            start = NSEvent.mouseLocation; origin = w.frame.origin; moved = false
            offsetY = NSEvent.mouseLocation.y - w.frame.minY
            m.dragging = true; m.brain.beginDrag()
        }
        host.dragged = { [weak m] _ in
            guard let m, let w = m.window, let s = start else { return }
            let p = NSEvent.mouseLocation
            if abs(p.x - s.x) + abs(p.y - s.y) > 4 { moved = true }
            w.setFrameOrigin(CGPoint(x: p.x - w.frame.width / 2, y: p.y - offsetY))
            _ = origin
        }
        host.up = { [weak self, weak m] _ in
            guard let self, let m, let w = m.window, let v = m.canvas else { return }
            m.dragging = false
            start = nil
            if moved {
                m.floorY = w.frame.minY + v.footInset
                m.brain.endDrag(at: w.frame.midX)
                if self.settings.layout == "walks" { m.home = w.frame.midX }   // her place goes with her
            } else {
                m.brain.endDrag(at: m.brain.x); m.brain.acknowledge(); m.brain.wave()
            }
        }
        host.right = { [weak self, weak host] e in if let self, let host { self.onRightClick(e, host) } }
    }

    private func tickWindow(_ m: FlockMember, dt: CFTimeInterval) {
        guard let w = m.window, let v = m.canvas else { return }
        let screen = AppDelegate.screen(nearest: CGPoint(x: m.brain.x, y: m.floorY))
        let vf = screen.visibleFrame
        let half = v.bounds.width / 2
        if settings.layout == "free" {
            m.brain.bounds = (vf.minX + half * 0.8)...max(vf.minX + half * 0.8 + 1, vf.maxX - half * 0.8)
        } else {
            m.brain.bounds = (m.home - 110)...(m.home + 110)
        }
        let head = CGPoint(x: m.brain.x, y: m.floorY + v.headHeight * 0.78)
        v.render(m.brain.step(dt: dt, cursor: NSEvent.mouseLocation, headPoint: head))
        if !m.dragging {
            let o = CGPoint(x: (m.brain.x - half).rounded(), y: (m.floorY - v.footInset).rounded())
            if abs(o.x - w.frame.minX) >= 1 || abs(o.y - w.frame.minY) >= 1 { w.setFrameOrigin(o) }
        }
        let soles = w.frame.minY + v.footInset
        let now = CACurrentMediaTime()
        m.bubble.follow(head: CGPoint(x: w.frame.midX, y: soles + v.headHeight + 4), feetY: soles, screen: screen, now: now)
        m.tag.follow(x: w.frame.midX, top: soles)
    }

    // ---------- the stage ----------
    /// Pets in the stage: "Medium" is the size that fits the desks; "Small" and "Large"
    /// scale from there. The office itself never changes size.
    /// A pet's view for the stage, at its size tier. Pixel art can only take sizes where
    /// each pixel of the drawing is a whole number of screen pixels, and how many of those
    /// sizes exist depends on the screen: on a non-Retina display Small and Medium both
    /// rounded to the same one, so "Medium" did nothing. The tiers are therefore chosen
    /// among the sizes this screen allows, and always three different ones.
    private func stageCanvas(_ m: FlockMember, _ sv: StageView) -> PetCanvas? {
        let medium = sv.scene.petHeight * sv.zoom
        // the density of the screen the stage is on, not of whichever screen has focus. A
        // window that has only just been ordered in may not know its screen yet: then the
        // screen is the one under its frame.
        let frame = sv.window?.frame ?? .zero
        let screen = sv.window?.screen
            ?? NSScreen.screens.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let backing = screen.backingScaleFactor
        guard let first = makeCanvas(m, height: medium * stageScale, backing: backing) else { return nil }
        guard let sprite = first as? SpriteView, sprite.sheet.pixelated, sprite.sheet.content.height > 0 else {
            return first
        }
        let sheet = sprite.sheet
        let steps = CGFloat(sheet.block) * backing        // allowed sizes: k / steps of the atlas size
        let km0 = medium / sheet.content.height * steps    // Medium, in steps, before rounding
        let ks = max(1, (km0 * 0.8).rounded())
        let km = max(km0.rounded(), ks + 1)
        let kl = max((km0 * 1.3).rounded(), km + 1)
        let k: CGFloat
        switch Int(settings.petHeight) {
        case 100: k = ks
        case 220: k = kl
        default:  k = km
        }
        let height = k / steps * sheet.content.height
        return abs(height - medium * stageScale) < 0.5 ? first : (makeCanvas(m, height: height, backing: backing) ?? first)
    }

    private var stageScale: CGFloat {
        [100: 0.8, 150: 1.0, 220: 1.3][Int(settings.petHeight)] ?? settings.petHeight / 150
    }

    private func openStage() {
        let scenes = Scene.scan()
        guard let sc = scenes.first(where: { $0.id == settings.scene }) ?? scenes.first else { return }
        let sv = StageView(scene: sc, zoom: settings.stageSize)
        let w = PetWindow(contentRect: sv.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false; w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = true; w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.contentView = sv
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        var o = settings.stageOrigin ?? CGPoint(x: vf.maxX - sv.bounds.width - 24, y: vf.minY + 30)
        // a saved spot on a screen that is gone: back to this one
        if !NSScreen.screens.contains(where: { $0.frame.contains(CGPoint(x: o.x + 10, y: o.y + 10)) }) {
            o = CGPoint(x: vf.maxX - sv.bounds.width - 24, y: vf.minY + 30)
        }
        w.setFrameOrigin(o)
        stageWindow = w; stageView = sv
        sv.onPetDown = { [weak self] p in
            guard let self, let m = self.petAt(p, in: sv) else { return false }
            m.dragging = true; m.brain.beginDrag()
            return true
        }
        sv.onPetDrag = { [weak self] p in
            guard let self, let m = self.members.values.first(where: { $0.dragging }) else { return }
            m.brain.place(x: min(max(p.x, sc.walk.lowerBound), sc.walk.upperBound))
        }
        sv.onPetUp = { [weak self] moved in
            guard let self, let m = self.members.values.first(where: { $0.dragging }) else { return }
            m.dragging = false
            m.brain.endDrag(at: m.brain.x)
            if !moved { m.brain.acknowledge(); m.brain.wave() }
        }
        sv.onMoved = { [weak self] o in self?.settings.stageOrigin = o; self?.onStageMoved(o) }
        sv.onRightClick = { [weak self, weak sv] e in if let self, let sv { self.onRightClick(e, sv) } }
        w.orderFrontRegardless()
    }

    private func petAt(_ p: CGPoint, in sv: StageView) -> FlockMember? {
        // scene point (y down) → stage view point (y up) → the pet's own coordinates
        let v = CGPoint(x: p.x * sv.zoom, y: (sv.scene.size.height - p.y) * sv.zoom)
        for m in members.values.sorted(by: { $0.brain.x > $1.brain.x }) {
            guard let c = m.canvas, let f = c.layer?.frame else { continue }
            if c.hitsPet(CGPoint(x: v.x - f.minX, y: v.y - f.minY)) { return m }
        }
        return nil
    }

    /// A pet's view is never shown as a view here: its layer hangs in the stage, between
    /// the back and the front (the desks).
    private func hang(_ c: PetCanvas, in sv: StageView) {
        c.wantsLayer = true
        if let l = c.layer { l.removeFromSuperlayer(); sv.add(l) }
    }

    private func placeInStage(_ m: FlockMember, _ sv: StageView) {
        let sc = sv.scene
        guard let c = stageCanvas(m, sv) else { return }
        m.canvas = c
        hang(c, in: sv)
        m.brain.walkOverride = 34
        m.brain.bounds = sc.walk
        assignDesks(sc)
        m.brain.place(x: sc.door)
        m.brain.walkTo(m.desk ?? CGFloat.random(in: sc.walk))
    }

    /// Each to her desk; with no desk left, they work standing next to the last one.
    private func assignDesks(_ sc: Scene) {
        var i = 0
        for k in order {
            guard let m = members[k], !m.leaving else { continue }
            m.desk = i < sc.desks.count ? sc.desks[i] : (sc.desks.last ?? sc.window) + 22 * CGFloat(i - sc.desks.count + 1)
            m.brain.spots = Brain.Spots(work: m.desk, wait: (m.desk ?? sc.window) + 18,
                                        rest: sc.rest - 14 * CGFloat(i % 3), window: sc.window)
            i += 1
        }
    }

    private func tickStage(dt: CFTimeInterval) {
        guard let sv = stageView, let w = stageWindow else { return }
        // an empty office can hide until somebody opens a session
        let empty = members.isEmpty
        if settings.hideEmptyStage, empty, w.isVisible { w.orderOut(nil) }
        else if (!settings.hideEmptyStage || !empty), !w.isVisible { w.orderFrontRegardless() }
        let sc = sv.scene, z = sv.zoom
        let mouse = NSEvent.mouseLocation
        let cursor = CGPoint(x: (mouse.x - w.frame.minX) / z, y: sc.size.height - (mouse.y - w.frame.minY) / z)
        let now = CACurrentMediaTime()
        let screen = w.screen ?? NSScreen.main ?? NSScreen.screens[0]
        var prev: (x: CGFloat, lift: CGFloat)?
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for m in members.values.sorted(by: { $0.brain.x < $1.brain.x }) {
            guard let c = m.canvas, let l = c.layer else { continue }
            let f = m.brain.step(dt: dt, cursor: cursor, headPoint: CGPoint(x: m.brain.x, y: sc.floor - sc.petHeight * 0.78))
            c.render(f)
            let cx = m.brain.x * z
            let feet = (sc.size.height - sc.floor) * z
            l.frame = CGRect(x: cx - c.bounds.width / 2, y: feet - c.footInset, width: c.bounds.width, height: c.bounds.height)
            let sx = w.frame.minX + cx, sy = w.frame.minY + feet
            // balloons that would overlap climb a step
            var lift: CGFloat = 0
            let talking = !m.brain.lastLine.isEmpty
            if talking, let p = prev, abs(sx - p.x) < 150 { lift = p.lift + 26 }
            m.bubble.follow(head: CGPoint(x: sx, y: sy + c.headHeight + 4 + lift), feetY: sy, screen: screen, now: now)
            if talking { prev = (sx, lift) }
            m.tag.follow(x: sx, top: sy)
        }
        CATransaction.commit()
    }

    // ---------- clock ----------
    func tick(dt: CFTimeInterval) {
        let now = CACurrentMediaTime()
        if now - lastRefresh > 1.5 { probe.refresh(now: now); lastRefresh = now; lastPoll = now }
        else if now - lastPoll > 0.2 { probe.poll(now: now); lastPoll = now }
        if now - lastSync > 0.5 { lastSync = now; sync() }
        if stageView != nil { tickStage(dt: dt) }
        else { for m in members.values { tickWindow(m, dt: dt) } }
    }
}
