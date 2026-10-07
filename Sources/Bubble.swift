import AppKit

/// What kind of thing the balloon is saying. It only changes the accent: a working
/// line is quiet, a line that needs you is warm, a landed answer is green, a turn
/// that ended on an error is red.
enum BubbleTone { case working, waiting, done, error }

/// The speech balloon she pops over her head.
///
/// It gets its own borderless window: the pet window is sized to her body plus a
/// couple of pixels of swing room, and the hit-testing in `MouseCatcher` assumes
/// every point in it belongs to her. Growing that window to fit a balloon would
/// break both. A separate, click-through window keeps the two independent.
final class Bubble {
    private let window: BalloonWindow
    private let view = BalloonView()
    private var hideAt: CFTimeInterval = -1
    private var fading = false
    private var appearing = false
    private var lastTone: BubbleTone = .working

    init() {
        window = BalloonWindow(contentRect: .zero, styleMask: [.borderless],
                               backing: .buffered, defer: false)
        // Windows made in code free themselves when closed (isReleasedWhenClosed), and
        // Swift then frees them again: closing a balloon or a tag crashed the app every
        // time the flock restarted (new stage, new size) or a pet left. Never again.
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // above the pets and the stage, which come to the front when clicked
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.contentView = view
        window.alphaValue = 0
    }

    /// For a pet that leaves for good (one pet per session).
    func close() { window.orderOut(nil); window.close() }

    /// `tag` goes in front, dimmed - the project, so with two sessions open the
    /// balloon says which one finished or which one is asking.
    func say(_ text: String, seconds: CFTimeInterval, tone: BubbleTone = .working, tag: String = "",
             now: CFTimeInterval) {
        // a new line while one is up just swaps the text; the pop is for a balloon
        // that was not there - or for one that changed tone, which is news
        let fresh = hideAt <= 0 || fading || tone != lastTone
        lastTone = tone
        view.set(text: text, tone: tone, tag: tag)
        window.setContentSize(view.naturalSize)
        hideAt = now + seconds
        fading = false
        appearing = appearing || fresh
    }

    /// Takes the balloon down early. Used for the line she holds while Claude writes:
    /// it has no duration of its own, it lasts exactly as long as the answer does.
    func hush(now: CFTimeInterval) {
        guard hideAt > 0 else { return }
        hideAt = now - 0.001        // already expired; `follow` fades it out
    }

    /// Pins the tail over her head and retires the balloon once its time is up.
    /// Called every frame, after the brain has moved her. `screen` is the one she is
    /// actually standing on: the balloon is kept inside it, and when she stands too
    /// close to its top for a balloon to fit, it hangs under her feet instead, tail up.
    func follow(head: CGPoint, feetY: CGFloat, screen: NSScreen, now: CFTimeInterval) {
        guard hideAt > 0 else { return }
        let w = window.frame.width, h = window.frame.height
        let vf = screen.visibleFrame
        let x = min(max(head.x - w/2, vf.minX + 6), vf.maxX - w - 6)
        let below = head.y + h > vf.maxY - 4
        let y = below ? max(feetY - h - 2, vf.minY + 4) : head.y
        window.setFrameOrigin(CGPoint(x: x, y: y))
        view.tailUp = below
        view.tailX = min(max((head.x - x)/max(w, 1), 0.16), 0.84)
        view.tick(now: now)

        // Always drive the alpha back up on a new line, not just when the window is
        // off screen. Saying something while the previous line is still fading out
        // left an in-flight animation heading for alpha 0 on a window that counts as
        // visible - so the balloon stayed mounted and completely transparent, and she
        // looked like she had stopped reacting.
        if appearing {
            appearing = false
            if !window.isVisible { window.alphaValue = 0 }
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { c in
                c.duration = 0.16
                window.animator().alphaValue = 1
            }
            view.pop()
        }
        if now > hideAt, !fading {
            fading = true
            NSAnimationContext.runAnimationGroup({ c in
                c.duration = 0.35
                window.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.fading else { return }
                self.window.orderOut(nil)
                self.hideAt = -1
                self.fading = false
            })
        }
    }
}

private final class BalloonWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Rounded rect and its tail drawn as one outline, pointing down at her head - or up
/// at her feet when the balloon had to go underneath her.
private final class BalloonView: NSView {
    var tailX: CGFloat = 0.5 { didSet { if tailX != oldValue { needsDisplay = true } } }
    var tailUp = false { didSet { if tailUp != oldValue { needsDisplay = true } } }

    private var lead = NSAttributedString()      // the verb, dimmed ("reading")
    private var body = NSAttributedString()      // what matters ("Brain.swift")
    private var textSize = CGSize.zero
    private var dots = false                     // a trailing "…" becomes three live dots
    private var dotStep = -1
    private var tone: BubbleTone = .working

    private static let padH: CGFloat = 12, padV: CGFloat = 7
    private static let tailH: CGFloat = 8, tailW: CGFloat = 14, radius: CGFloat = 11
    private static let maxTextWidth: CGFloat = 230
    private static let dotR: CGFloat = 1.7, dotGap: CGFloat = 5.2

    private static let font: NSFont = {
        let base = NSFont.systemFont(ofSize: 13, weight: .medium)
        guard let d = base.fontDescriptor.withDesign(.rounded),
              let f = NSFont(descriptor: d, size: 13) else { return base }
        return f
    }()

    /// The verbs the brain puts in front of a detail. Dimming them is what makes
    /// "reading Brain.swift" read as *Brain.swift* at a glance.
    private static let leads: Set<String> = ["reading", "writing", "running", "searching", "helper:"]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { fatalError() }

    private static func attributed(_ s: String, color: NSColor) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        p.alignment = .center
        return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
    }

    func set(text: String, tone: BubbleTone, tag: String = "") {
        self.tone = tone
        var s = text
        // split "verb detail" into a dim lead and a bright body; anything else is
        // all body
        var leadStr = "", bodyStr = s
        if let sp = s.firstIndex(of: " "), Self.leads.contains(String(s[..<sp])) {
            leadStr = String(s[...sp]); bodyStr = String(s[s.index(after: sp)...])
        }
        // The live dots stand in for the "…" of a line that is waiting on something
        // ("thinking…", "on it…"). A detail that ends in "…" was cut short by the
        // hook, and that ellipsis has to stay as text.
        dots = leadStr.isEmpty && s.hasSuffix("…")
        if dots { s.removeLast(); bodyStr = s }
        let t = tag.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { leadStr = t + " · " + leadStr }
        lead = Self.attributed(leadStr, color: .secondaryLabelColor)
        body = Self.attributed(bodyStr, color: .labelColor)
        let whole = NSMutableAttributedString(attributedString: lead); whole.append(body)
        let r = whole.boundingRect(with: CGSize(width: Self.maxTextWidth, height: .greatestFiniteMagnitude),
                                   options: [.usesLineFragmentOrigin])
        let lineH = Self.font.ascender - Self.font.descender + Self.font.leading
        textSize = CGSize(width: ceil(r.width), height: min(ceil(r.height), ceil(lineH*2) + 1))
        dotStep = -1
        needsDisplay = true
    }

    var naturalSize: NSSize {
        NSSize(width: textSize.width + Self.padH*2 + (dots ? Self.dotGap*3 : 0),
               height: textSize.height + Self.padV*2 + Self.tailH)
    }

    /// Advances the dots. Only redraws when the lit dot moves, so a held line costs
    /// nothing between steps.
    func tick(now: CFTimeInterval) {
        guard dots else { return }
        let step = Int(now * 2.6) % 3
        if step != dotStep { dotStep = step; needsDisplay = true }
    }

    /// A short bounce out of the tail tip, for a balloon that was not there before.
    func pop() {
        guard let l = layer else { return }
        let tip = CGPoint(x: bounds.width * tailX, y: tailUp ? bounds.height : 0)
        func about(_ s: CGFloat) -> NSValue {
            var t = CATransform3DMakeTranslation(tip.x, tip.y, 0)
            t = CATransform3DScale(t, s, s, 1)
            t = CATransform3DTranslate(t, -tip.x, -tip.y, 0)
            return NSValue(caTransform3D: t)
        }
        let a = CAKeyframeAnimation(keyPath: "transform")
        a.values = [about(0.72), about(1.05), about(1)]
        a.keyTimes = [0, 0.62, 1]
        a.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        a.duration = 0.32
        l.removeAnimation(forKey: "pop")
        l.add(a, forKey: "pop")
    }

    private var accent: NSColor? {
        switch tone {
        case .working: return nil
        case .waiting: return .systemOrange
        case .done:    return .systemGreen
        case .error:   return .systemRed
        }
    }

    /// The outline: rounded rect with the tail cut into its bottom (or top) edge, so
    /// the border and the shadow run around the whole shape without a seam.
    private func outline() -> NSBezierPath {
        let r = Self.radius, th = Self.tailH, tw = Self.tailW
        let box = NSRect(x: 0.5, y: tailUp ? 0.5 : th + 0.5,
                         width: bounds.width - 1, height: bounds.height - th - 1)
        let tx = min(max(bounds.width * tailX, box.minX + r + tw/2 + 2), box.maxX - r - tw/2 - 2)
        let p = NSBezierPath()
        // clockwise from the top-left corner, with the tail spliced into one edge
        p.move(to: NSPoint(x: box.minX, y: box.maxY - r))
        p.appendArc(withCenter: NSPoint(x: box.minX + r, y: box.maxY - r), radius: r, startAngle: 180, endAngle: 90, clockwise: true)
        if tailUp {
            p.line(to: NSPoint(x: tx - tw/2, y: box.maxY))
            p.line(to: NSPoint(x: tx, y: box.maxY + th - 0.5))
            p.line(to: NSPoint(x: tx + tw/2, y: box.maxY))
        }
        p.line(to: NSPoint(x: box.maxX - r, y: box.maxY))
        p.appendArc(withCenter: NSPoint(x: box.maxX - r, y: box.maxY - r), radius: r, startAngle: 90, endAngle: 0, clockwise: true)
        p.line(to: NSPoint(x: box.maxX, y: box.minY + r))
        p.appendArc(withCenter: NSPoint(x: box.maxX - r, y: box.minY + r), radius: r, startAngle: 0, endAngle: -90, clockwise: true)
        if !tailUp {
            p.line(to: NSPoint(x: tx + tw/2, y: box.minY))
            p.line(to: NSPoint(x: tx, y: box.minY - th + 0.5))
            p.line(to: NSPoint(x: tx - tw/2, y: box.minY))
        }
        p.line(to: NSPoint(x: box.minX + r, y: box.minY))
        p.appendArc(withCenter: NSPoint(x: box.minX + r, y: box.minY + r), radius: r, startAngle: -90, endAngle: -180, clockwise: true)
        p.close()
        return p
    }

    override func draw(_ dirty: NSRect) {
        guard textSize.width > 0 else { return }
        let shape = outline()

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = 9
        shadow.shadowOffset = NSSize(width: 0, height: -2.5)
        shadow.set()
        NSColor.windowBackgroundColor.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        // a hairline keeps it legible on a desktop the same colour as the balloon;
        // a line that needs you gets the accent on the rim too, so it reads from
        // across the room
        if let a = accent {
            a.withAlphaComponent(0.10).setFill(); shape.fill()
            a.withAlphaComponent(0.75).setStroke()
        } else {
            NSColor.labelColor.withAlphaComponent(0.14).setStroke()
        }
        shape.lineWidth = 1
        shape.stroke()

        // text, centred in the body, with the dots hanging off its end
        let bodyMinY = tailUp ? 0 : Self.tailH
        let dotsW = dots ? Self.dotGap*3 : 0
        let textRect = NSRect(x: (bounds.width - textSize.width - dotsW)/2,
                              y: bodyMinY + Self.padV,
                              width: textSize.width, height: textSize.height)
        let whole = NSMutableAttributedString(attributedString: lead); whole.append(body)
        whole.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        if dots {
            // sit on the baseline of the last line
            let base = textRect.minY + Self.dotR + 1.5
            for i in 0..<3 {
                let cx = textRect.maxX + Self.dotGap*CGFloat(i) + Self.dotGap*0.6
                let lit = i == dotStep
                NSColor.labelColor.withAlphaComponent(lit ? 0.9 : 0.28).setFill()
                NSBezierPath(ovalIn: NSRect(x: cx - Self.dotR, y: base - Self.dotR,
                                            width: Self.dotR*2, height: Self.dotR*2)).fill()
            }
        }
    }
}
