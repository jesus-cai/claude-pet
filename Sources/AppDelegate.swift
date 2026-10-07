import AppKit
import ImageIO
import ServiceManagement

final class PetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var window: PetWindow!
    private var view: PetCanvas!
    private var brain: Brain!
    private var timer: Timer?
    private var link: AnyObject?          // CADisplayLink, macOS 14+
    private var statusItem: NSStatusItem!
    private var lastTick = CACurrentMediaTime()

    private var dragOrigin: CGPoint?
    private var dragMoved = false
    private var dragOffsetY: CGFloat = 0

    /// Where her soles stand, in screen coordinates. The x lives in the brain because
    /// walking moves it; the y only changes when she is dropped somewhere.
    private var feetY: CGFloat = 0

    private let bubble = Bubble()
    /// The one probe. In the classic mode it is also the pet's feed.
    private let probe = ClaudeProbe()
    private let notifier = Notifier()
    private var pets: [PetEntry] = []
    /// One pet per session (off: the classic single pet).
    private var flock: Flock!
    private var multi: Bool { flag("multi", false) }
    private var currentNotices: [String: Brain.Notice] { multi && flock != nil ? flock.notices() : brain.notices }
    private var pet: PetEntry?
    private var baseIcon: NSImage?
    private var shownBadge: NSColor?
    private var badgeKnown = false

    private let d = UserDefaults.standard
    private var petHeight: CGFloat { max(90, CGFloat(d.object(forKey: "petHeight") as? Double ?? 150)) }
    private func flag(_ key: String, _ def: Bool = true) -> Bool { d.object(forKey: key) as? Bool ?? def }
    private static let env = ProcessInfo.processInfo.environment

    func applicationDidFinishLaunching(_ n: Notification) {
        try? FileManager.default.createDirectory(at: PetLibrary.userPets, withIntermediateDirectories: true)

        let screen = NSScreen.main ?? NSScreen.screens[0]
        // Quit with her on a monitor that is gone by the next launch and the saved spot
        // lands off every screen; only a saved x that is still on some screen is used.
        let vf = screen.visibleFrame
        let savedX = (d.object(forKey: "petX") as? Double).map { CGFloat($0) }
        let savedY = (d.object(forKey: "petY") as? Double).map { CGFloat($0) }
        var start = CGPoint(x: vf.midX, y: Self.floorY(of: screen))
        if let x = savedX, let s = NSScreen.screens.first(where: { $0.frame.minX <= x && x < $0.frame.maxX }) {
            start = CGPoint(x: x, y: savedY ?? Self.floorY(of: s))
        }
        brain = Brain(startX: start.x, feed: probe)
        feetY = start.y
        syncSwitches()
        brain.speak = { [weak self] text, seconds, tone, tag in
            self?.bubble.say(text, seconds: seconds, tone: tone, tag: tag, now: CACurrentMediaTime())
        }
        brain.hush = { [weak self] in self?.bubble.hush(now: CACurrentMediaTime()) }
        brain.alert = { [weak self] e in self?.notifier.alert(e) }
        // the sessions taken off by hand stay off across launches
        if let saved = d.dictionary(forKey: "hiddenSessions") as? [String: [Double]] {
            // Claude Desktop is not kept: it comes back when it answers or closes anyway
            probe.restoreHidden(saved.filter { $0.key != "desktop" }.compactMapValues { v -> ClaudeProbe.Hidden? in
                v.count == 2 ? ClaudeProbe.Hidden(open: v[0] != 0, at: Date(timeIntervalSince1970: v[1])) : nil
            })
        }
        probe.onHiddenChange = { [weak self] in
            guard let self else { return }
            self.d.set(self.probe.hidden.mapValues { [$0.open ? 1.0 : 0.0, $0.at.timeIntervalSince1970] },
                       forKey: "hiddenSessions")
        }

        window = PetWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar   // sits over fullscreen apps too
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isMovableByWindowBackground = false
        window.ignoresMouseEvents = false

        pets = PetLibrary.scan()
        guard choosePet(d.string(forKey: "petID") ?? "mochi") else {
            let a = NSAlert()
            a.messageText = "No encontré ninguna mascota."
            a.informativeText = "Pon una carpeta con pet.json y spritesheet.webp en \(PetLibrary.userPets.path)"
            a.runModal(); NSApp.terminate(nil); return
        }
        window.orderFrontRegardless()
        buildStatusItem()
        startClock()
        flock = Flock(probe: probe, settings: flockSettings(), catalog: { [weak self] in self?.pets ?? [] },
                      alert: { [weak self] e in self?.notifier.alert(e) })
        flock.onStageMoved = { [weak self] o in
            self?.d.set(Double(o.x), forKey: "stageX"); self?.d.set(Double(o.y), forKey: "stageY")
        }
        flock.onRightClick = { [weak self] e, v in
            if let self { NSMenu.popUpContextMenu(self.buildMenu(), with: e, for: v) }
        }
        if multi { applyMode() }
    }

    // MARK: pets

    /// Switches to the pet with this id, or the closest thing that loads: the default
    /// one, then any. False only when nothing at all loads.
    @discardableResult
    private func choosePet(_ id: String) -> Bool {
        var order = pets.filter { $0.id == id }
        order += pets.filter { $0.id == "mochi" && $0.id != id }
        order += pets.filter { $0.id != id && $0.id != "mochi" }
        for e in order {
            pet = e
            if rebuildView() {
                d.set(e.id, forKey: "petID")
                return true
            }
        }
        pet = nil
        return false
    }

    /// Drives the animation off the display's own refresh. A 60 Hz `Timer` is not
    /// aligned to vsync, which is the stutter you see even when nothing is dropped.
    /// The display link also stops on its own when the screen sleeps; nothing is lost
    /// by that any more, since finished turns are noticed by their file and not by
    /// being watched at the right moment.
    private func startClock() {
        if #available(macOS 14.0, *) { (link as? CADisplayLink)?.invalidate() }
        link = nil
        timer?.invalidate(); timer = nil
        // One pet per session hides the classic pet's window, and a display link bound
        // to a hidden window gets no frames: the whole flock froze, the stage showing
        // its background and nothing else. That mode runs on a plain timer.
        let forceTimer = Self.env["COMPA_CLOCK"] == "timer" || multi
        if #available(macOS 14.0, *), !forceTimer, let host = window.contentView {
            let l = host.displayLink(target: self, selector: #selector(onFrame))
            l.add(to: .main, forMode: .common)
            link = l
        } else {
            let t = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        lastTick = CACurrentMediaTime()
    }

    @objc private func onFrame() { tick() }

    func applicationWillTerminate(_ n: Notification) {
        if let brain { d.set(Double(brain.x), forKey: "petX"); d.set(Double(feetY), forKey: "petY") }
    }

    /// Builds the view for the current pet. False when its files don't load.
    @discardableResult
    private func rebuildView() -> Bool {
        guard let pet else { return false }
        let backing = currentScreen.backingScaleFactor
        guard let v = PetLibrary.makeCanvas(pet, petHeight: petHeight, backing: backing,
                                            preferPixels: flag("pixels")) else { return false }
        builtForBacking = backing
        view = v
        brain.setPersonality(reactions: pet.reactions, lines: pet.lines)
        brain.scale = v.rigScale       // a rig's stride is measured in canonical pixels
        brain.cell = v.rigCell         // ...and in pixel mode, so is its breathing
        brain.walkOverride = v.walkSpeed
        if let s = v as? SpriteView {
            brain.hasLook = s.sheet.look.count == 16
            brain.hasTalk = s.hasTalk
        } else {
            brain.hasLook = false
            brain.hasTalk = false
        }
        v.wantsLayer = true
        let host = MouseCatcher(frame: v.bounds)
        host.owner = self
        host.addSubview(v)
        window.setContentSize(v.bounds.size)
        window.contentView = host
        host.frame = v.bounds
        baseIcon = v.menubarIcon
        badgeKnown = false
        // The display link is bound to the content view, and this just replaced it.
        // Without rebinding, any change from the menu froze her solid.
        if statusItem != nil { startClock() }
        return true
    }
    private var builtForBacking: CGFloat = 2

    /// The soles right now: while she is being carried, wherever the window is.
    private var feetPoint: CGPoint {
        dragOrigin != nil ? CGPoint(x: window.frame.midX, y: window.frame.minY + view.footInset)
                          : CGPoint(x: brain.x, y: feetY)
    }

    /// The screen she stands on, chosen by the whole point (monitors stacked one
    /// above another share their x range).
    private var currentScreen: NSScreen { Self.screen(nearest: feetPoint) }

    static func floorY(of screen: NSScreen) -> CGFloat { screen.visibleFrame.minY + 2 }

    static func screen(nearest p: CGPoint) -> NSScreen {
        if let s = NSScreen.screens.first(where: { $0.frame.contains(p) }) { return s }
        func gap(_ r: CGRect) -> CGFloat {
            let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
            return dx*dx + dy*dy
        }
        return NSScreen.screens.min { gap($0.frame) < gap($1.frame) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func tick() {
        guard view != nil else { return }
        let now = CACurrentMediaTime()
        let dt = min(0.05, now - lastTick); lastTick = now
        if multi {   // the flock runs everything then
            flock.tick(dt: dt); updateBadge()
            if Self.env["COMPA_DEBUG"] != nil, Int(now * 2) != debugTick {
                debugTick = Int(now * 2)
                FileHandle.standardError.write("\(Self.stamp.string(from: Date())) \(flock.debugLine())\n".data(using: .utf8)!)
            }
            return
        }

        let screen = currentScreen
        let vf = screen.visibleFrame
        let half = view.bounds.width/2
        brain.bounds = (vf.minX + half*0.55)...(vf.maxX - half*0.55)

        if dragOrigin == nil {
            feetY = min(max(feetY, Self.floorY(of: screen)), vf.maxY - view.headHeight - 4)
        }
        let headScreen = CGPoint(x: brain.x, y: feetY + view.headHeight*0.78)
        let frame = brain.step(dt: dt, cursor: NSEvent.mouseLocation, headPoint: headScreen)
        view.render(frame)

        if dragOrigin == nil {
            // snapped to the grid and only when it actually moved: every setFrameOrigin
            // is a round trip to the window server
            let px = view.motionGrid > 0 ? view.motionGrid
                                         : 1 / (window.backingScaleFactor > 0 ? window.backingScaleFactor : 2)
            let want = CGPoint(x: (brain.x - half) - ((brain.x - half).truncatingRemainder(dividingBy: px)),
                               y: feetY - view.footInset)
            if abs(want.x - window.frame.minX) >= px || abs(want.y - window.frame.minY) >= px {
                window.setFrameOrigin(want)
            }
        }
        let soles = window.frame.minY + view.footInset
        bubble.follow(head: CGPoint(x: window.frame.midX, y: soles + view.headHeight + 4),
                      feetY: soles, screen: screen, now: now)
        if let dir = Self.env["COMPA_QA"], now - lastQA > qaEvery {
            lastQA = now
            if let img = view.snapshot() {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(String(format: "q%03d.png", qaIndex))
                qaIndex += 1
                if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
                }
            }
            if qaIndex > (Int(Self.env["COMPA_QA_FRAMES"] ?? "") ?? 40) { NSApp.terminate(nil) }
        }
        updateBadge()
        // the pixel grid is snapped to one screen's density; another density re-snaps
        if view.snapsToBacking, currentScreen.backingScaleFactor != builtForBacking { rebuildView() }

        frames += 1
        worstGap = max(worstGap, dt)
        if Self.env["COMPA_DEBUG"] != nil, Int(now*2) != debugTick {
            debugTick = Int(now*2)
            let fps = Double(frames) / max(0.001, now - statWindow)
            let c = probe
            let line = "\(Self.stamp.string(from: Date())) pet=\(pet?.id ?? "-") wid=\(window.windowNumber) "
                + "x=\(Int(brain.x)) y=\(Int(feetY)) act=\(brain.activity) clip=\(brain.clip) look=\(brain.look.map { String($0) } ?? "-") "
                + "say=\"\(brain.lastLine)\" notices=\(brain.notices.count)[\(Brain.projectList(brain.notices))] sessions=\(probe.sessions.count) "
                + "fps=\(String(format: "%.0f", fps)) worstFrame=\(String(format: "%.1fms", worstGap*1000)) "
                + "claude(run=\(c.isRunning) front=\(c.isFrontmost) state=\(c.state.rawValue) detail=\(c.detail) "
                + "project=\(c.project) signal=\(c.isSignalled) cpu=\(String(format: "%.2f", c.cpu)))\n"
            FileHandle.standardError.write(line.data(using: .utf8)!)
            frames = 0; worstGap = 0; statWindow = now
        }
    }
    private var frames = 0
    private var worstGap: CFTimeInterval = 0
    private var statWindow: CFTimeInterval = 0
    private var lastQA: CFTimeInterval = 0
    private let qaEvery = Double(AppDelegate.env["COMPA_QA_EVERY"] ?? "") ?? 0.55
    private var qaIndex = 0
    private var debugTick = -1
    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    /// Dot on the menu bar icon for whatever is pending, so it can be seen even when
    /// she is on another screen or behind a window.
    private func updateBadge() {
        var color: NSColor?
        if flag("reactsToClaude") {
            if probe.state == .waiting { color = .systemOrange }
            else if currentNotices.values.contains(where: { $0.kind == .error }) { color = .systemRed }
            else if !currentNotices.isEmpty { color = .systemGreen }
        }
        if badgeKnown, color == shownBadge { return }
        badgeKnown = true
        shownBadge = color
        if let img = Notifier.badged(baseIcon, color) {
            statusItem.button?.image = img
            statusItem.button?.title = ""
        } else {
            statusItem.button?.image = nil
            statusItem.button?.title = color == nil ? "◉" : "●"
        }
    }

    // MARK: mouse

    func petMouseDown(_ e: NSEvent) {
        dragOrigin = NSEvent.mouseLocation
        dragMoved = false
        dragOffsetY = NSEvent.mouseLocation.y - window.frame.minY
        brain.beginDrag()
    }

    func petMouseDragged(_ e: NSEvent) {
        guard let start = dragOrigin else { return }
        let m = NSEvent.mouseLocation
        if abs(m.x - start.x) + abs(m.y - start.y) > 4 { dragMoved = true }
        window.setFrameOrigin(CGPoint(x: m.x - window.frame.width/2, y: m.y - dragOffsetY))
    }

    func petMouseUp(_ e: NSEvent) {
        let m = NSEvent.mouseLocation
        dragOrigin = nil
        if dragMoved {
            feetY = window.frame.minY + view.footInset
            brain.endDrag(at: m.x)
            d.set(Double(brain.x), forKey: "petX"); d.set(Double(feetY), forKey: "petY")
        } else {
            // a click: whatever she was holding up for you, you've seen it
            brain.endDrag(at: brain.x)
            brain.acknowledge()
            brain.wave()
        }
    }

    func petRightMouseDown(_ e: NSEvent) {
        NSMenu.popUpContextMenu(buildMenu(), with: e, for: view)
    }

    // MARK: menu

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateBadge()
    }

    @objc private func toggle(_ item: NSMenuItem) {
        guard let key = item.representedObject as? String else { return }
        let wanted = !flag(key, Self.defaultOn(key))
        d.set(wanted, forKey: key)
        if key == "pixels" { rebuildView() }
        syncSwitches()
        if key == "multi" { applyMode() }
        else if multi { flock.settings = flockSettings(); flock.applySwitches() }
    }

    private static func defaultOn(_ key: String) -> Bool { !["banners", "multi", "hideEmptyStage"].contains(key) }

    // ---------- one pet per session ----------
    private func flockSettings() -> FlockSettings {
        var s = FlockSettings()
        s.by = Assign.By(rawValue: d.string(forKey: "by") ?? "mix") ?? .mix
        s.layout = d.string(forKey: "layout") ?? "stage"
        s.scene = d.string(forKey: "scene") ?? "oficina"
        s.stageSize = 2      // the stage always at its small size; "Size" is for the pets
        s.rotation = d.stringArray(forKey: "rotation") ?? []
        s.pins = loadPins()
        s.mainPet = pet?.id ?? d.string(forKey: "petID") ?? "mochi"
        s.petHeight = petHeight
        if let x = d.object(forKey: "stageX") as? Double, let y = d.object(forKey: "stageY") as? Double {
            s.stageOrigin = CGPoint(x: x, y: y)
        }
        s.wanders = flag("wanders"); s.followsCursor = flag("followsCursor")
        s.reactsToClaude = flag("reactsToClaude"); s.announces = flag("announces")
        s.hideEmptyStage = flag("hideEmptyStage", false)
        return s
    }

    private func loadPins() -> [String: Assign.Pin] {
        guard let raw = d.dictionary(forKey: "pins") else { return [:] }
        var out: [String: Assign.Pin] = [:]
        for (k, v) in raw {
            guard let v = v as? [String: Any] else { continue }
            out[k] = Assign.Pin(pet: v["pet"] as? String, color: (v["color"] as? NSNumber)?.intValue)
        }
        return out
    }

    private func savePins(_ pins: [String: Assign.Pin]) {
        var raw: [String: Any] = [:]
        for (k, p) in pins {
            var v: [String: Any] = [:]
            if let pet = p.pet { v["pet"] = pet }
            if let c = p.color { v["color"] = c }
            if !v.isEmpty { raw[k] = v }
        }
        d.set(raw, forKey: "pins")
    }

    private func applyMode() {
        if multi {
            window.orderOut(nil)
            bubble.hush(now: CACurrentMediaTime())
            flock.settings = flockSettings()
            flock.start()
        } else {
            flock.stop()
            window.orderFrontRegardless()
        }
        badgeKnown = false
        startClock()      // timer for the flock, display link again for the classic pet
    }

    /// Restarts the flock with the current settings (layout, scene, size changed).
    private func restartFlock(resetLooks: Bool = false) {
        guard multi else { return }
        if resetLooks { flock.resetAssignments() }
        flock.settings = flockSettings()
        flock.start()
    }

    @objc private func setOption(_ item: NSMenuItem) {
        guard let kv = item.representedObject as? [Any], kv.count == 2, let key = kv[0] as? String else { return }
        d.set(kv[1], forKey: key)
        if key == "by" { flock.resetAssignments(); flock.settings = flockSettings() }
        else { restartFlock() }
    }

    @objc private func toggleRotation(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        let all = pets.map { $0.id }
        var rot = d.stringArray(forKey: "rotation") ?? []
        if rot.isEmpty { rot = all }
        if rot.contains(id) { rot.removeAll { $0 == id } } else { rot.append(id) }
        d.set(rot.isEmpty || rot.count >= all.count ? [] : rot, forKey: "rotation")   // empty = all
        flock.resetAssignments(); flock.settings = flockSettings()
    }

    @objc private func pinPet(_ item: NSMenuItem) {
        guard let kv = item.representedObject as? [String], kv.count == 2 else { return }
        var pins = loadPins()
        var p = pins[kv[0]] ?? Assign.Pin()
        p.pet = kv[1].isEmpty ? nil : kv[1]
        pins[kv[0]] = p
        savePins(pins)
        flock.resetAssignments(); flock.settings = flockSettings()
    }

    @objc private func pinColor(_ item: NSMenuItem) {
        guard let kv = item.representedObject as? [Any], kv.count == 2, let project = kv[0] as? String,
              let c = kv[1] as? Int else { return }
        var pins = loadPins()
        var p = pins[project] ?? Assign.Pin()
        p.color = c < 0 ? nil : c
        pins[project] = p
        savePins(pins)
        flock.resetAssignments(); flock.settings = flockSettings()
    }

    private func syncSwitches() {
        brain.wanders = flag("wanders")
        brain.followsCursor = flag("followsCursor")
        brain.reactsToClaude = flag("reactsToClaude")
        brain.announces = flag("announces")
        notifier.sound = flag("sound")
        notifier.banners = flag("banners", false)
    }

    /// "Size" sizes the pets, everywhere. The stage keeps its one (small) size: it is
    /// big enough already, and only the pets inside it grow or shrink.
    @objc private func setSize(_ item: NSMenuItem) {
        d.set(Double(item.tag), forKey: "petHeight")
        rebuildView()
        restartFlock()
    }

    @objc private func pickPet(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        choosePet(id)
        if multi { flock.resetAssignments(); flock.settings = flockSettings() }
    }

    @objc private func reloadPets() {
        pets = PetLibrary.scan()
        choosePet(pet?.id ?? "mochi")
        if multi { flock.forgetSheets(); restartFlock() }
    }

    @objc private func openPetsFolder() {
        try? FileManager.default.createDirectory(at: PetLibrary.userPets, withIntermediateDirectories: true)
        NSWorkspace.shared.open(PetLibrary.userPets)
    }

    @objc private func openPetdex() {
        if let u = URL(string: "https://petdex.crafter.run") { NSWorkspace.shared.open(u) }
    }

    @objc private func doWave() { if multi { flock.wave() } else { brain.wave() } }
    @objc private func markSeen() { if multi { flock.acknowledge() } else { brain.acknowledge() } }
    @objc private func markSessionSeen(_ item: NSMenuItem) {
        guard let key = item.representedObject as? String else { return }
        if multi { flock.acknowledge(key) } else { brain.acknowledge(session: key) }
    }
    /// Off the list and without a pet until that session gets back to work.
    @objc private func hideSession(_ item: NSMenuItem) {
        guard let key = item.representedObject as? String else { return }
        // Claude Desktop taken off mid-answer has not finished: no party for it
        if key == "desktop", !multi, probe.desktopBusy { brain.dropStretch() }
        if multi { flock.acknowledge(key) } else { brain.acknowledge(session: key) }
        probe.hide(key)
        probe.poll(now: CACurrentMediaTime())
    }
    @objc private func unhideSessions() {
        probe.unhideAll()
        probe.poll(now: CACurrentMediaTime())
    }
    private func seenItem(_ key: String) -> NSMenuItem {
        let it = NSMenuItem(title: "Marcar como visto", action: #selector(markSessionSeen(_:)), keyEquivalent: "")
        it.target = self; it.representedObject = key
        return it
    }
    private func hideItem(_ key: String) -> NSMenuItem {
        let it = NSMenuItem(title: "Quitar esta sesión", action: #selector(hideSession(_:)), keyEquivalent: "")
        it.target = self; it.representedObject = key
        it.toolTip = "Vuelve sola cuando le escribas otra vez"
        return it
    }
    /// The rescue item: middle of the screen she is on, feet on the floor.
    @objc private func recenter() {
        if multi { flock.recenter(); return }
        let s = currentScreen
        feetY = Self.floorY(of: s)
        brain.endDrag(at: s.visibleFrame.midX)
    }
    @objc private func toggleLogin() {
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
        else { try? SMAppService.mainApp.register() }
    }
    @objc private func quit() { NSApp.terminate(nil) }

    /// Rebuilt every time it opens, so the session list is always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        fill(menu)
    }

    private func buildMenu() -> NSMenu {
        let m = NSMenu()
        fill(m)
        return m
    }

    /// What one session is doing, for the menu.
    private func describe(_ x: ClaudeProbe.SessionInfo) -> String {
        let d = x.detail.trimmingCharacters(in: .whitespaces)
        func with(_ verb: String) -> String { d.isEmpty ? verb : "\(verb) \(d)" }
        switch x.state {
        case .thinking:   return d.isEmpty ? "pensando…" : d
        case .reading:    return with("leyendo")
        case .writing:    return with("escribiendo")
        case .running:    return with("ejecutando")
        case .searching:  return with("buscando")
        case .delegating: return with("delegando")
        case .waiting:    return "te espera" + (d.isEmpty ? "" : ": \(d)")
        case .done:       return "terminó"
        case .stopped:    return "interrumpido"
        case .error:      return "error"
        case .idle:       return "en reposo"
        }
    }

    private func fill(_ m: NSMenu) {
        let c = probe
        let status: String
        switch c.state {
        case .thinking:   status = "Claude pensando…"
        case .reading:    status = "Claude leyendo…"
        case .writing:    status = "Claude escribiendo…"
        case .running:    status = "Claude ejecutando…"
        case .searching:  status = "Claude buscando…"
        case .delegating: status = "Claude delegando…"
        case .waiting:    status = "Claude te espera"
        case .done:       status = "Claude terminó"
        case .stopped:    status = "Claude interrumpido"
        case .error:      status = "Claude: error"
        case .idle:
            if !c.isRunning { status = "Claude cerrado" }
            else if c.isFrontmost { status = "Claude al frente" }
            else { status = "Claude abierto" }
        }
        let where_ = c.project.isEmpty ? "" : " (\(c.project))"
        var sessions = c.sessions
        // Claude Desktop as one more "session": its own pet with several pets, and in the
        // classic mode while it answers or has a notice you have not seen
        if probe.desktopRunning, !probe.isHidden("desktop"),
           multi || probe.desktopBusy || currentNotices["desktop"] != nil {
            sessions.append(ClaudeProbe.SessionInfo(key: "desktop", project: "Claude Desktop",
                                                    state: probe.desktopBusy ? .thinking : .idle, age: 0,
                                                    detail: "", at: .distantPast))
        }
        let headTitle = sessions.count > 1 ? "\(pet?.name ?? "Compa") · \(sessions.count) sesiones"
                                           : "\(pet?.name ?? "Compa") · \(status)\(where_)"
        let head = NSMenuItem(title: headTitle, action: nil, keyEquivalent: "")
        head.isEnabled = false
        m.addItem(head)

        // one line per Claude Code session, even a single one (that is where it is
        // taken off by hand); a pending notice is marked, and its submenu marks it seen
        let notices = currentNotices
        if !sessions.isEmpty {
            for x in sessions {
                let pending = notices[x.key]
                var mark = "   "
                if x.state == .waiting { mark = "🟠 " }
                else if let p = pending { mark = p.kind == .error ? "🔴 " : "🟢 " }
                else if x.state.isWorking { mark = "⏳ " }
                let name = x.project.isEmpty ? String(x.key.prefix(8)) : x.project
                var line = "\(mark)\(name) — \(describe(x))"
                if pending != nil { line += " (sin ver)" }
                if line.count > 70 { line = String(line.prefix(69)) + "…" }
                let it = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                it.representedObject = x.key
                if multi {
                    // one pet per session: each session pins its pet and its colour
                    it.submenu = pinMenu(project: x.project.isEmpty ? name : x.project, key: x.key, pending: pending != nil)
                } else {
                    let sub = NSMenu()
                    if pending != nil { sub.addItem(seenItem(x.key)) }
                    sub.addItem(hideItem(x.key))
                    it.submenu = sub
                }
                m.addItem(it)
            }
        }
        if !probe.hidden.isEmpty {
            let n = probe.hidden.count
            m.addItem(withTitle: n > 1 ? "Volver a mostrar las \(n) sesiones quitadas" : "Volver a mostrar la sesión quitada",
                      action: #selector(unhideSessions), keyEquivalent: "").target = self
        }
        m.addItem(.separator())

        if !notices.isEmpty {
            let title = notices.count > 1 ? "Marcar los \(notices.count) avisos como vistos"
                                                : "Marcar aviso como visto"
            m.addItem(withTitle: title, action: #selector(markSeen), keyEquivalent: "").target = self
        }
        m.addItem(withTitle: "Saludar", action: #selector(doWave), keyEquivalent: "").target = self
        m.addItem(withTitle: "Traer al centro", action: #selector(recenter), keyEquivalent: "").target = self
        m.addItem(.separator())

        // pets
        let petsMenu = NSMenu()
        for e in pets {
            let it = NSMenuItem(title: e.name, action: #selector(pickPet(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = e.id
            it.state = e.id == pet?.id ? .on : .off
            it.toolTip = "\(e.origin) · \(e.folder.path)"
            petsMenu.addItem(it)
        }
        petsMenu.addItem(.separator())
        petsMenu.addItem(withTitle: "Abrir carpeta de mascotas", action: #selector(openPetsFolder), keyEquivalent: "").target = self
        petsMenu.addItem(withTitle: "Buscar más mascotas (petdex)…", action: #selector(openPetdex), keyEquivalent: "").target = self
        petsMenu.addItem(withTitle: "Volver a buscar mascotas", action: #selector(reloadPets), keyEquivalent: "").target = self
        let petsItem = NSMenuItem(title: "Mascota", action: nil, keyEquivalent: "")
        m.addItem(petsItem); m.setSubmenu(petsMenu, for: petsItem)

        var toggles: [(String, String)] = []
        if pet?.hasPixelVariant == true { toggles.append(("Modo píxel", "pixels")) }
        toggles += [("Que camine sola", "wanders"),
                    ("Que siga el cursor", "followsCursor"),
                    ("Que reaccione a Claude", "reactsToClaude"),
                    ("Que avise con un globito", "announces")]
        m.addItem(toggleItem("Una mascota por sesión", "multi"))
        if multi { addFlockMenu(m) }
        for (title, key) in toggles { m.addItem(toggleItem(title, key)) }

        let alerts = NSMenu()
        alerts.addItem(toggleItem("Sonido", "sound"))
        alerts.addItem(toggleItem("Notificaciones del sistema", "banners"))
        let alertsItem = NSMenuItem(title: "Avisos", action: nil, keyEquivalent: "")
        m.addItem(alertsItem); m.setSubmenu(alerts, for: alertsItem)
        m.addItem(.separator())

        let sizes = NSMenu()
        for (title, h) in [("Pequeña", 100), ("Mediana", 150), ("Grande", 220)] {
            let it = NSMenuItem(title: title, action: #selector(setSize(_:)), keyEquivalent: "")
            it.target = self; it.tag = h
            it.state = Int(petHeight) == h ? .on : .off
            sizes.addItem(it)
        }
        let sizeItem = NSMenuItem(title: "Tamaño", action: nil, keyEquivalent: "")
        m.addItem(sizeItem); m.setSubmenu(sizes, for: sizeItem)

        let login = NSMenuItem(title: "Abrir al iniciar sesión", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        m.addItem(login)
        m.addItem(.separator())
        m.addItem(withTitle: "Salir", action: #selector(quit), keyEquivalent: "q").target = self
    }

    private func addFlockMenu(_ m: NSMenu) {
        let sub = NSMenu()
        func radio(_ title: String, _ key: String, _ value: Any, _ on: Bool) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: #selector(setOption(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = [key, value] as [Any]; it.state = on ? .on : .off
            return it
        }
        func group(_ title: String, _ items: [NSMenuItem]) {
            let g = NSMenu(); items.forEach { g.addItem($0) }
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: ""); sub.addItem(it); sub.setSubmenu(g, for: it)
        }
        let s = flockSettings()
        group("Distinguir por", [radio("Mascota distinta", "by", "pet", s.by == .pet),
                                 radio("Color distinto", "by", "color", s.by == .color),
                                 radio("Mezcla de ambas", "by", "mix", s.by == .mix)])
        group("Disposición", [radio("Escenario", "layout", "stage", s.layout == "stage"),
                              radio("Paseos cortos", "layout", "walks", s.layout == "walks"),
                              radio("Libres", "layout", "free", s.layout == "free")])
        group("Escenario", Scene.scan().map { radio($0.name, "scene", $0.id, s.scene == $0.id) })
        let rot = d.stringArray(forKey: "rotation") ?? []
        group("Mascotas en rotación", pets.map { p in
            let it = NSMenuItem(title: p.name, action: #selector(toggleRotation(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = p.id
            it.state = rot.isEmpty || rot.contains(p.id) ? .on : .off
            return it
        })
        sub.addItem(.separator())
        sub.addItem(toggleItem("Ocultar el escenario si no hay sesiones", "hideEmptyStage"))
        let it = NSMenuItem(title: "Varias mascotas", action: nil, keyEquivalent: "")
        m.addItem(it); m.setSubmenu(sub, for: it)
    }

    private func pinMenu(project: String, key: String, pending: Bool) -> NSMenu {
        let sub = NSMenu()
        if pending { sub.addItem(seenItem(key)) }
        sub.addItem(hideItem(key))
        sub.addItem(.separator())
        let pin = loadPins()[project] ?? Assign.Pin()
        let head = NSMenuItem(title: "Mascota de «\(project)»", action: nil, keyEquivalent: ""); head.isEnabled = false
        sub.addItem(head)
        let atlas = pets
        for (title, id) in [("Automática", "")] + atlas.map({ ($0.name, $0.id) }) {
            let it = NSMenuItem(title: title, action: #selector(pinPet(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = [project, id]
            it.state = (pin.pet ?? "") == id ? .on : .off
            sub.addItem(it)
        }
        sub.addItem(.separator())
        let ch = NSMenuItem(title: "Color", action: nil, keyEquivalent: ""); ch.isEnabled = false
        sub.addItem(ch)
        for (i, c) in [(-1, "Automático")] + Assign.palette.enumerated().map({ ($0.offset, $0.element.name) }) {
            let it = NSMenuItem(title: c, action: #selector(pinColor(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = [project, i] as [Any]
            it.state = (pin.color ?? -1) == i ? .on : .off
            sub.addItem(it)
        }
        return sub
    }

    private func toggleItem(_ title: String, _ key: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: #selector(toggle(_:)), keyEquivalent: "")
        it.target = self; it.representedObject = key
        it.state = flag(key, Self.defaultOn(key)) ? .on : .off
        return it
    }
}

/// Forwards mouse events from the shaped pet view up to the delegate.
final class MouseCatcher: NSView {
    weak var owner: AppDelegate?
    override func mouseDown(with e: NSEvent) { owner?.petMouseDown(e) }
    override func mouseDragged(with e: NSEvent) { owner?.petMouseDragged(e) }
    override func mouseUp(with e: NSEvent) { owner?.petMouseUp(e) }
    override func rightMouseDown(with e: NSEvent) { owner?.petRightMouseDown(e) }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let pet = subviews.first as? PetCanvas else { return nil }
        return pet.hitsPet(convert(point, from: superview)) ? self : nil
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}
