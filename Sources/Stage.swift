import AppKit
import ImageIO

/// A stage: a little office (or cabin…) where every pet lives when there are several.
/// Two layers - what is behind the pets and what is in front of them (the desks, which
/// hide their lower half so they look sat down working, whatever pet it is) - and a
/// scene.json with the spots: door, desks, rest, window, and where they can walk.
struct Scene {
    let id: String
    let name: String
    let size: CGSize               // scene pixels
    let floor: CGFloat             // where the feet go (y down)
    let petHeight: CGFloat         // scene pixels
    let pixelated: Bool
    let walk: ClosedRange<CGFloat>
    let door: CGFloat
    let desks: [CGFloat]
    let rest: CGFloat
    let window: CGFloat
    let back: CGImage
    let front: CGImage?

    static func scan() -> [Scene] {
        var dirs = [PetLibrary.home.appendingPathComponent("scenes")]
        if let b = Bundle.main.resourceURL?.appendingPathComponent("scenes") { dirs.append(b) }
        var out: [Scene] = [], seen = Set<String>()
        let fm = FileManager.default
        for d in dirs {
            let items = ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for f in items {
                guard let s = load(f), !seen.contains(s.id) else { continue }
                seen.insert(s.id); out.append(s)
            }
        }
        return out
    }

    static func load(_ f: URL) -> Scene? {
        guard let d = try? Data(contentsOf: f.appendingPathComponent("scene.json")),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let back = image(f.appendingPathComponent("back.png")) else { return nil }
        func num(_ k: String, _ def: CGFloat) -> CGFloat { CGFloat((j[k] as? NSNumber)?.doubleValue ?? Double(def)) }
        let size = (j["size"] as? [NSNumber]).map { CGSize(width: $0[0].doubleValue, height: $0[1].doubleValue) }
            ?? CGSize(width: back.width, height: back.height)
        let walk = (j["walk"] as? [NSNumber]).map { CGFloat($0[0].doubleValue)...CGFloat($0[1].doubleValue) }
            ?? 10...(size.width - 10)
        return Scene(id: j["id"] as? String ?? f.lastPathComponent, name: j["name"] as? String ?? f.lastPathComponent,
                     size: size, floor: num("floor", size.height - 12), petHeight: num("petHeight", 40),
                     pixelated: j["pixelated"] as? Bool ?? true, walk: walk, door: num("door", walk.lowerBound),
                     desks: (j["desks"] as? [NSNumber])?.map { CGFloat($0.doubleValue) } ?? [],
                     rest: num("rest", walk.upperBound), window: num("window", size.width / 2),
                     back: back, front: image(f.appendingPathComponent("front.png")))
    }

    static func image(_ u: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

/// The stage's window: back layer, one layer per pet, front layer. The whole thing
/// moves by dragging the scene; a pet is picked up by dragging the pet.
final class StageView: NSView {
    let scene: Scene
    let zoom: CGFloat
    private let backLayer = CALayer(), frontLayer = CALayer(), petsLayer = CALayer()
    var onPetDown: ((CGPoint) -> Bool)?        // scene point; true = a pet took it
    var onPetDrag: ((CGPoint) -> Void)?
    var onPetUp: ((Bool) -> Void)?             // moved?
    var onMoved: ((CGPoint) -> Void)?          // new window origin
    var onRightClick: ((NSEvent) -> Void)?
    private var dragging: (pet: Bool, start: CGPoint, origin: CGPoint, moved: Bool)?

    init(scene: Scene, zoom: CGFloat) {
        self.scene = scene; self.zoom = zoom
        super.init(frame: CGRect(x: 0, y: 0, width: scene.size.width * zoom, height: scene.size.height * zoom))
        wantsLayer = true
        let root = CALayer()
        layer = root
        for (l, img) in [(backLayer, scene.back as CGImage?), (frontLayer, scene.front)] {
            l.frame = bounds; l.contents = img
            l.magnificationFilter = scene.pixelated ? .nearest : .linear
        }
        petsLayer.frame = bounds
        root.addSublayer(backLayer); root.addSublayer(petsLayer); root.addSublayer(frontLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    func add(_ l: CALayer) { petsLayer.addSublayer(l) }

    /// Scene point (y down) of a point in this view.
    func scenePoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / zoom, y: scene.size.height - p.y / zoom) }

    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) {
        let p = scenePoint(convert(e.locationInWindow, from: nil))
        let pet = onPetDown?(p) ?? false
        dragging = (pet, NSEvent.mouseLocation, window?.frame.origin ?? .zero, false)
        if !pet { NSCursor.closedHand.push() }
    }
    override func mouseDragged(with e: NSEvent) {
        guard var d = dragging, let w = window else { return }
        let m = NSEvent.mouseLocation
        if abs(m.x - d.start.x) + abs(m.y - d.start.y) > 3 { d.moved = true }
        dragging = d
        if d.pet { onPetDrag?(scenePoint(convert(e.locationInWindow, from: nil))) }
        else { w.setFrameOrigin(CGPoint(x: d.origin.x + m.x - d.start.x, y: d.origin.y + m.y - d.start.y)) }
    }
    override func mouseUp(with e: NSEvent) {
        guard let d = dragging else { return }
        dragging = nil
        if d.pet { onPetUp?(d.moved) } else { NSCursor.pop(); if let o = window?.frame.origin { onMoved?(o) } }
    }
    override func rightMouseDown(with e: NSEvent) { onRightClick?(e) }
}

/// A little pill under a pet with its project, in its colour. Its own tiny window, so
/// it works the same under a free pet and inside the stage.
final class Tag {
    private let window: NSWindow
    private let view = TagView()

    init() {
        window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        // Windows made in code free themselves when closed (isReleasedWhenClosed), and
        // Swift then frees them again: closing a balloon or a tag crashed the app every
        // time the flock restarted (new stage, new size) or a pet left. Never again.
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // one level above the stage and the pets: clicking the stage brings it to the
        // front, and at the same level it covered every tag (they sit inside it, at the feet)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.contentView = view
    }

    func set(_ text: String, color: NSColor) {
        guard text != view.text || color != view.dot else { return }
        view.text = text; view.dot = color
        let size = view.fittingSize
        window.setContentSize(size)
        view.needsDisplay = true
        window.orderFrontRegardless()
    }

    /// Centred under the feet: `top` is the screen y of the soles.
    func follow(x: CGFloat, top: CGFloat) {
        let f = window.frame
        let o = CGPoint(x: (x - f.width / 2).rounded(), y: (top - f.height - 2).rounded())
        if abs(o.x - f.minX) >= 1 || abs(o.y - f.minY) >= 1 { window.setFrameOrigin(o) }
    }

    func close() { window.orderOut(nil); window.close() }
}

private final class TagView: NSView {
    var text = ""
    var dot: NSColor = .gray
    private var attrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: NSColor.white]
    }
    override var fittingSize: NSSize {
        let s = (text as NSString).size(withAttributes: attrs)
        return NSSize(width: ceil(s.width) + 24, height: 17)
    }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        NSColor(white: 0.1, alpha: 0.78).setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        dot.setFill()
        NSBezierPath(ovalIn: NSRect(x: 7, y: bounds.midY - 3, width: 6, height: 6)).fill()
        (text as NSString).draw(at: NSPoint(x: 17, y: (bounds.height - 13) / 2), withAttributes: attrs)
    }
}
