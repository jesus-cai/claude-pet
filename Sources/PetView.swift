import AppKit

/// Composites the layered rig with Core Animation layers. One layer per body part,
/// each rotating about its own joint, so the whole figure stays crisp at any size.
final class PetView: PetCanvas {
    let rig: Rig
    private var layersByName: [String: CALayer] = [:]
    private let root = CALayer()
    private var box: CGRect = .zero          // canonical rect mapped onto the view
    private(set) var scale: CGFloat = 1      // canonical pixels to points

    private var feet: CGFloat = 0

    override var footInset: CGFloat { feet }
    override var headHeight: CGFloat { rig.content.height * scale }
    override var motionGrid: CGFloat { rig.pixel > 0 ? rig.pixel * scale : 0 }
    override var rigScale: CGFloat { scale }
    override var rigCell: CGFloat { rig.pixel }
    override var snapsToBacking: Bool { rig.pixel > 0 }
    override var menubarIcon: NSImage? {
        guard let img = NSImage(contentsOf: rig.directory.appendingPathComponent("menubar.png")) else { return nil }
        img.size = NSSize(width: 18, height: 18)
        return img
    }
    override func render(_ frame: PetFrame) { apply(frame.pose) }

    init(rig: Rig, petHeight: CGFloat, backing: CGFloat = 2) {
        self.rig = rig
        // room around her for swinging limbs and the hop, in fractions of her own
        // size so the asset resolution can change without resizing the window
        box = rig.content.insetBy(dx: -rig.content.width*0.14, dy: 0)
        box.origin.y -= rig.content.height*0.130     // headroom for the celebration hop
        box.size.height += rig.content.height*0.165  // ...plus the old 3.5% under her feet
        scale = petHeight / rig.content.height

        if rig.pixel > 0 {
            // The canvas has to start and end on the sprite grid: every layer rect is a
            // multiple of `pixel`, so a canvas that isn't lands every part on a fraction
            // of a pixel and the whole figure sampled slightly differently.
            let p = rig.pixel
            let minX = (box.minX/p).rounded(.down)*p, maxX = (box.maxX/p).rounded(.up)*p
            let minY = (box.minY/p).rounded(.down)*p, maxY = (box.maxY/p).rounded(.up)*p
            // one free cell all around, so nothing ever ends flush with the edge
            box = CGRect(x: minX - p, y: minY - p, width: maxX - minX + 2*p, height: maxY - minY + 2*p)
            // ...and one sprite pixel has to be a whole number of screen pixels, or the
            // blocks come out uneven and shimmer as she moves
            let zoom = max(1, (scale * p * backing).rounded())
            scale = zoom / (p * backing)
        }

        super.init(frame: CGRect(origin: .zero,
                                 size: CGSize(width: box.width*scale, height: box.height*scale)))
        layer = root
        wantsLayer = true
        root.masksToBounds = false
        buildLayers()
        feet = (box.maxY - rig.floor) * scale
    }
    required init?(coder: NSCoder) { fatalError() }

    private func viewPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - box.minX)*scale, y: (box.maxY - p.y)*scale)
    }

    private func buildLayers() {
        for name in Rig.order {
            guard let part = rig.parts[name] else { continue }
            let l = CALayer()
            l.contents = part.image
            let filter: CALayerContentsFilter = rig.pixel > 0 ? .nearest : .trilinear
            l.magnificationFilter = filter
            l.minificationFilter = filter
            let origin = viewPoint(CGPoint(x: part.rect.minX, y: part.rect.maxY))
            l.frame = CGRect(x: origin.x, y: origin.y,
                             width: part.rect.width*scale, height: part.rect.height*scale)
            if let pivot = pivotFor(name) {
                let v = viewPoint(pivot)
                l.anchorPoint = CGPoint(x: (v.x - l.frame.minX)/l.frame.width,
                                        y: (v.y - l.frame.minY)/l.frame.height)
                l.position = v
            }
            if name.hasPrefix("lid") { l.opacity = 0 }
            root.addSublayer(l)
            layersByName[name] = l
        }
    }

    private func pivotFor(_ name: String) -> CGPoint? {
        switch name {
        case "head", "lidL", "lidR", "irisL", "irisR": return rig.pivots["head"]
        case "body": return rig.pivots["body"]
        case "armL": return rig.pivots["armL"]
        case "armR": return rig.pivots["armR"]
        case "legL": return rig.pivots["legL"]
        case "legR": return rig.pivots["legR"]
        default: return nil
        }
    }

    private func rot(_ deg: CGFloat) -> CATransform3D {
        CATransform3DMakeRotation(deg * .pi / 180, 0, 0, 1)
    }

    private var spinning: [String: CGFloat] = [:]

    /// Shows the limb's pre-drawn sprite for the angle closest to `deg`.
    private func spin(_ name: String, _ deg: CGFloat) {
        guard let part = rig.parts[name], let l = layersByName[name],
              let img = part.spun(deg) else { return }
        if spinning[name] != deg {          // CALayer contents assignment is not free
            spinning[name] = deg
            if l.contents as AnyObject? !== img { l.contents = img }
        }
    }

    /// Everything lands on the sprite grid. Amplitudes are the Brain's problem: it
    /// authors the small channels in whole cells when `cell > 0`, because scaling them
    /// up here needed one gain per channel and every gain was wrong for some state -
    /// the one that made breathing visible turned the celebration crouch into a squat.
    private func snap(_ v: CGFloat, _ gain: CGFloat = 1) -> CGFloat {
        rig.pixel > 0 ? (v*gain/rig.pixel).rounded()*rig.pixel : v
    }

    /// A sprite scaled by 1.014 doubles one row of pixels and leaves the rest alone,
    /// which shimmers. Rounded to whole cells it either squashes or it doesn't.
    private func snapScale(_ v: CGFloat, over size: CGFloat) -> CGFloat {
        guard rig.pixel > 0, size > 0 else { return v }
        return ((size*v/rig.pixel).rounded()*rig.pixel)/size
    }

    private func apply(_ pose: Pose) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let s = scale
        // mirroring the whole rig is what turns her around
        // AppKit pins a backing layer's anchor point at (0,0), so the mirror has to
        // be bracketed by translations or she flips clean off the canvas.
        let rootDY = snap(pose.rootDY)
        let bodyDY = snap(pose.bodyDY)
        let headDX = snap(pose.headDX)
        let headDY = snap(pose.headDY + pose.bodyDY)
        let irisDX = snap(pose.irisDX), irisDY = snap(pose.irisDY)
        let bodyH = rig.parts["body"]?.rect.height ?? 0
        let headW = rig.parts["head"]?.rect.width ?? 0
        let bodyScaleY = snapScale(pose.bodyScaleY, over: bodyH)
        let bodyScaleX = snapScale(pose.bodyScaleX, over: rig.parts["body"]?.rect.width ?? 0)
        let headSquashX = snapScale(pose.headSquashX, over: headW)
        // The head carries the face, and turning it by a few degrees resamples the eyes
        // into a different shape every frame. Torso and head only translate in pixel
        // mode; the limbs keep their turn because theirs is baked, not sampled.
        let bodyRot = rig.pixel > 0 ? 0 : pose.bodyRot
        let headRot = rig.pixel > 0 ? 0 : pose.headRot

        var rootT = CATransform3DMakeTranslation(bounds.midX + snap(pose.rootDX)*s, -rootDY*s, 0)
        rootT = CATransform3DScale(rootT, pose.facing, 1, 1)
        rootT = CATransform3DTranslate(rootT, -bounds.midX, 0, 0)
        root.sublayerTransform = rootT

        func set(_ name: String, _ t: CATransform3D) { layersByName[name]?.transform = t }

        var bodyT = CATransform3DMakeTranslation(0, -bodyDY*s, 0)
        bodyT = CATransform3DConcat(rot(bodyRot), bodyT)
        bodyT = CATransform3DScale(bodyT, bodyScaleX, bodyScaleY, 1)
        set("body", bodyT)

        var headT = CATransform3DMakeTranslation(headDX*s, -headDY*s, 0)
        headT = CATransform3DConcat(rot(headRot), headT)
        headT = CATransform3DScale(headT, headSquashX, 1, 1)
        for n in ["head", "lidL", "lidR"] { set(n, headT) }

        // irises ride the head, then slide inside the eye
        let irisT = CATransform3DTranslate(headT, irisDX*s/headSquashX, -irisDY*s, 0)
        set("irisL", irisT); set("irisR", irisT)

        let shoulder = CATransform3DMakeTranslation(0, -bodyDY*s, 0)
        if rig.parts["armL"]?.spin.isEmpty == false {
            // baked angles: swap the image, never turn the layer
            spin("armL", pose.armLRot); set("armL", shoulder)
            spin("armR", pose.armRRot); set("armR", shoulder)
            spin("legL", pose.legLRot); set("legL", CATransform3DIdentity)
            spin("legR", pose.legRRot); set("legR", CATransform3DIdentity)
        } else {
            set("armL", CATransform3DConcat(rot(pose.armLRot), shoulder))
            set("armR", CATransform3DConcat(rot(pose.armRRot), shoulder))
            set("legL", rot(pose.legLRot))
            set("legR", rot(pose.legRRot))
        }

        layersByName["lidL"]?.opacity = Float(pose.lidOpacity)
        layersByName["lidR"]?.opacity = Float(pose.lidOpacity)

        if let sh = layersByName["shadow"] {
            // the shadow belongs to the floor, so it has to sit out the hop: undo
            // exactly what the root transform above added to it
            var shT = CATransform3DMakeTranslation(0, rootDY*s, 0)
            shT = CATransform3DScale(shT, pose.shadowScale, 1, 1)
            sh.transform = shT
            sh.opacity = Float(pose.shadowOpacity)
        }
        CATransaction.commit()
    }

    /// True when the point (in this view's own coordinates) lands on her, not on
    /// the transparent margin, so clicks elsewhere fall through to the desktop.
    override func hitsPet(_ local: CGPoint) -> Bool {
        let nx = (local.x/scale + box.minX - rig.content.minX) / rig.content.width
        let ny = (local.y/scale - (box.maxY - rig.content.maxY)) / rig.content.height
        return rig.isOpaque(atNormalised: CGPoint(x: nx, y: ny))
    }

    /// Off-screen snapshot of the live layer tree, used for animation QA.
    override func snapshot() -> CGImage? {
        let w = Int(bounds.width*2), h = Int(bounds.height*2)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.scaleBy(x: 2, y: 2)
        root.render(in: ctx)
        return ctx.makeImage()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let s = window?.backingScaleFactor ?? 2
        root.contentsScale = s
        root.sublayers?.forEach { $0.contentsScale = s }
    }
}
