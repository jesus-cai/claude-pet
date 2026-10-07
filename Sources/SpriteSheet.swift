import AppKit
import ImageIO
import CoreImage

/// A Codex pet atlas: 8 columns of 192x208 cells. Version 1 has 9 rows, one per
/// animation; version 2 adds two more with 16 look directions, clockwise from straight
/// up. This is the format of the `hatch-pet` skill and of every pet made for Codex, so
/// whatever you drop into `~/.compa/pets` or already have in `~/.codex/pets` just works.
///
/// The atlas does not have to be exactly 1536 wide: any width divisible by 8 is read,
/// and the cell height follows from the row count. Codex itself is stricter.
struct SpriteSheet {
    /// Coarse alpha map of one frame, y down, for click-through and for measuring.
    struct Mask {
        let w: Int, h: Int
        let data: [UInt8]

        func opaque(nx: CGFloat, ny: CGFloat) -> Bool {
            let x = Int(nx * CGFloat(w)), y = Int(ny * CGFloat(h))
            guard x >= 0, y >= 0, x < w, y < h else { return false }
            return data[y*w + x] > 40
        }

        /// Bounding box of the opaque pixels, in mask pixels, y down. nil when empty.
        var bounds: CGRect? {
            var minX = w, minY = h, maxX = -1, maxY = -1
            for y in 0..<h {
                for x in 0..<w where data[y*w + x] > 40 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
            guard maxX >= 0 else { return nil }
            return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }

        /// The opaque part without stray specks (a sparkle, a glint, a lost pixel), in
        /// mask pixels: the box of the blobs that count and their mass (opaque pixels).
        /// A speck far from the body used to widen the box, and the pet came out smaller.
        func measure() -> (box: CGRect, mass: Int)? {
            var label = [Int32](repeating: -1, count: w*h)
            var comps: [(n: Int, x0: Int, y0: Int, x1: Int, y1: Int)] = []
            var stack: [Int] = []
            var total = 0
            for i in 0..<(w*h) where data[i] > 40 && label[i] < 0 {
                var c = (n: 0, x0: w, y0: h, x1: -1, y1: -1)
                let id = Int32(comps.count)
                label[i] = id
                stack.append(i)
                while let j = stack.popLast() {
                    let x = j % w, y = j / w
                    c.n += 1
                    c.x0 = Swift.min(c.x0, x); c.x1 = Swift.max(c.x1, x)
                    c.y0 = Swift.min(c.y0, y); c.y1 = Swift.max(c.y1, y)
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let nx = x + dx, ny = y + dy
                            guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                            let k = ny*w + nx
                            if data[k] > 40 && label[k] < 0 { label[k] = id; stack.append(k) }
                        }
                    }
                }
                comps.append(c)
                total += c.n
            }
            guard total > 0 else { return nil }
            let least = Swift.max(3, Double(total) * 0.03)
            var box: CGRect?
            var mass = 0
            for c in comps where Double(c.n) >= least {
                mass += c.n
                let b = CGRect(x: c.x0, y: c.y0, width: c.x1 - c.x0 + 1, height: c.y1 - c.y0 + 1)
                box = box.map { $0.union(b) } ?? b
            }
            guard let box else { return nil }
            return (box, mass)
        }
    }

    struct Row {
        var frames: [CGImage] = []
        var masks: [Mask] = []
        var durations: [CFTimeInterval] = []

        /// The frame on screen `t` seconds into the row, looping.
        func frame(at t: CFTimeInterval) -> Int {
            let total = durations.reduce(0, +)
            guard total > 0, frames.count > 1 else { return 0 }
            var rest = t.truncatingRemainder(dividingBy: total)
            for (i, d) in durations.enumerated() {
                if rest < d { return i }
                rest -= d
            }
            return frames.count - 1
        }
    }

    /// Frame counts and timings straight from the hatch-pet contract (milliseconds).
    static let schedule: [(SpriteClip, [Int])] = [
        (.idle,     [280, 110, 110, 140, 140, 320]),
        (.runRight, [120, 120, 120, 120, 120, 120, 120, 220]),
        (.runLeft,  [120, 120, 120, 120, 120, 120, 120, 220]),
        (.waving,   [140, 140, 140, 280]),
        (.jumping,  [140, 140, 140, 140, 280]),
        (.failed,   [140, 140, 140, 140, 140, 140, 140, 240]),
        (.waiting,  [150, 150, 150, 150, 150, 260]),
        (.working,  [120, 120, 120, 120, 120, 220]),
        (.review,   [150, 150, 150, 150, 150, 280]),
    ]

    let rows: [SpriteClip: Row]
    /// Optional one-shot strips played when a row starts, before it loops (pulling
    /// something out, sitting down...). From `"introSheets"` in pet.json.
    let intros: [SpriteClip: Row]
    let look: [(image: CGImage, mask: Mask)]
    /// One cell, in atlas pixels.
    let cellSize: CGSize
    /// Where the pet stands inside its cell (union of the idle frames), atlas pixels,
    /// y down. Its bottom is the floor; its height is what "size" means.
    let content: CGRect
    /// Pixel art gets nearest-neighbour scaling and whole-pixel steps; anything else
    /// is smoothed.
    let pixelated: Bool
    let icon: CGImage?
    /// A grey pet is tinted (keeping its shading); a coloured one has its hue turned,
    /// from `hue` (degrees, its dominant one) to the colour asked for.
    let gray: Bool
    let hue: CGFloat
    /// Pixel art is often drawn small and scaled up: one pixel of the drawing is a
    /// block of `block`×`block` atlas pixels (4 for Mochi and Bober). Snapping has to
    /// keep those blocks whole, not each atlas pixel - snapping atlas pixels left only
    /// two sizes to choose from in the stage, and "Medium" came out as "Small".
    let block: Int
    /// How many rows were drawn smaller than the idle one and had to be blown up (debug).
    let scaledRows: Int

    init?(url: URL, version: Int, pixelated forced: Bool?, talk: URL? = nil, talkMs: Int = 110,
          intros introURLs: [String: URL] = [:], introMs: Int = 140) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let atlas = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let W = atlas.width, H = atlas.height
        guard W >= 8, W % 8 == 0 else { return nil }
        let cw = W / 8
        // the row count decides the cell height: whichever of 9 or 11 rows gives the
        // standard 192:208 cell, unless the manifest already says it is version 2
        let wanted = Double(cw) * 208 / 192
        let count: Int
        if version >= 2 { count = 11 }
        else { count = abs(Double(H)/11 - wanted) < abs(Double(H)/9 - wanted) ? 11 : 9 }
        let ch = H / count
        guard ch > 0 else { return nil }
        let mw = max(24, cw/2), mh = max(26, ch/2)

        func cell(_ r: Int, _ c: Int) -> CGImage? {
            atlas.cropping(to: CGRect(x: c*cw, y: r*ch, width: cw, height: ch))
        }

        var rows: [SpriteClip: Row] = [:]
        for (clip, ms) in Self.schedule where clip.rawValue < count {
            var row = Row()
            for (c, d) in ms.enumerated() {
                // community atlases sometimes leave a frame out; skip it rather than
                // flash an empty cell
                guard let img = cell(clip.rawValue, c) else { continue }
                let m = Self.mask(img, w: mw, h: mh)
                guard m.bounds != nil else { continue }
                row.frames.append(img); row.masks.append(m); row.durations.append(Double(d)/1000)
            }
            if !row.frames.isEmpty { rows[clip] = row }
        }
        guard let idle = rows[.idle] else { return nil }
        // extra strips: one row of cells the same size as the atlas's, any count
        func strip(_ url: URL, ms: Int) -> Row? {
            guard let ts = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(ts, 0, nil),
                  img.height == ch, img.width >= cw else { return nil }
            var row = Row()
            for c in 0..<(img.width / cw) {
                guard let f = img.cropping(to: CGRect(x: c*cw, y: 0, width: cw, height: ch)) else { continue }
                let m = Self.mask(f, w: mw, h: mh)
                guard m.bounds != nil else { continue }
                row.frames.append(f); row.masks.append(m); row.durations.append(Double(max(40, ms))/1000)
            }
            return row.frames.isEmpty ? nil : row
        }
        if let talk, let r = strip(talk, ms: talkMs) { rows[.talking] = r }
        var intros: [SpriteClip: Row] = [:]
        for (name, url) in introURLs {
            if let clip = SpriteClip(name: name), let r = strip(url, ms: introMs) { intros[clip] = r }
        }

        var look: [(image: CGImage, mask: Mask)] = []
        if count >= 11 {
            for r in 9...10 {
                for c in 0..<8 {
                    guard let img = cell(r, c) else { continue }
                    look.append((img, Self.mask(img, w: mw, h: mh)))
                }
            }
            // a direction row with holes would make her look straight at nothing
            if look.count != 16 || look.contains(where: { $0.mask.bounds == nil }) { look = [] }
        }

        let pixelated = forced ?? Self.looksPixelated(idle.frames[0])
        self.pixelated = pixelated
        let info = Self.colorInfo(idle.frames[0])
        gray = info.0
        hue = info.1
        block = Self.pixelBlock(idle.frames[0])

        // where she stands in her cell, and every row at the same scale as the idle one
        let fit = Self.evenOut(rows: &rows, look: &look, intros: &intros,
                               cell: CGSize(width: cw, height: ch), mw: mw, mh: mh, pixelated: pixelated)
        self.rows = rows
        self.intros = intros
        self.look = look
        cellSize = fit.cell
        content = fit.content
        scaledRows = fit.scaled

        // menu bar icon: the first idle frame cropped square around her
        let side = max(content.width, content.height)
        let sq = CGRect(x: content.midX - side/2, y: content.midY - side/2, width: side, height: side)
            .intersection(CGRect(origin: .zero, size: fit.cell))
        icon = (rows[.idle] ?? idle).frames[0].cropping(to: sq.integral)
    }

    // ---- every row at the idle scale ----
    //
    // Community pets (petdex) sometimes draw each animation at its own scale: the
    // Pikachu runs at two thirds of its idle size, feet in the air. A row clearly
    // smaller than the idle one - by mass, which does not change with the pose - is
    // blown up to it and stood on the same floor. Falling (failed) and jumping are
    // left alone: shrinking there is usually on purpose.

    private enum Fit { case move, stand, keep }
    private enum Slot: Hashable { case row(SpriteClip), intro(SpriteClip), look }
    private struct Grow { let k: CGFloat, cx: CGFloat, bottom: CGFloat }

    private static func fit(_ c: SpriteClip) -> Fit {
        switch c {
        case .runRight, .runLeft: return .move
        case .failed, .jumping: return .keep
        default: return .stand
        }
    }

    /// Measures the idle row (its box is what "size" means) and blows up the rows that
    /// are too small. If one no longer fits its cell, every cell grows the same. Frames
    /// are replaced in place; returns the new measures.
    private static func evenOut(rows: inout [SpriteClip: Row], look: inout [(image: CGImage, mask: Mask)],
                                intros: inout [SpriteClip: Row], cell: CGSize, mw: Int, mh: Int,
                                pixelated: Bool) -> (cell: CGSize, content: CGRect, scaled: Int) {
        let kx = cell.width / CGFloat(mw), ky = cell.height / CGFloat(mh)
        func toCell(_ b: CGRect) -> CGRect {
            CGRect(x: b.minX * kx, y: b.minY * ky, width: b.width * kx, height: b.height * ky)
        }
        func median(_ v: [Int]) -> Int { let s = v.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }

        let idle = (rows[.idle]?.masks ?? []).compactMap { $0.measure() }
        var box: CGRect?
        for m in idle { box = box.map { $0.union(m.box) } ?? m.box }
        let content = toCell(box ?? CGRect(x: 0, y: 0, width: mw, height: mh))
        let idleMass = Double(median(idle.map { $0.mass }))
        let mid = content.midX, floor = content.maxY

        var groups: [(slot: Slot, kind: Fit, masks: [Mask])] = []
        for (c, r) in rows where c != .idle { groups.append((slot: Slot.row(c), kind: fit(c), masks: r.masks)) }
        if !look.isEmpty { groups.append((slot: Slot.look, kind: Fit.stand, masks: look.map { $0.mask })) }
        for (c, r) in intros { groups.append((slot: Slot.intro(c), kind: fit(c), masks: r.masks)) }

        var plan: [Slot: Grow] = [:]
        var minX: CGFloat = 0, maxX = cell.width, minY: CGFloat = 0
        for g in groups where g.kind != .keep {
            let ms = g.masks.compactMap { $0.measure() }
            guard !ms.isEmpty else { continue }
            let k = (idleMass / Double(max(1, median(ms.map { $0.mass })))).squareRoot()
            guard k >= (g.kind == .move ? 1.12 : 1.2) else { continue }
            var u = ms[0].box
            for m in ms.dropFirst() { u = u.union(m.box) }
            u = toCell(u)
            let t = Grow(k: CGFloat(min(k, 1.6)), cx: u.midX, bottom: u.maxY)
            minX = min(minX, mid + (u.minX - t.cx) * t.k)
            maxX = max(maxX, mid + (u.maxX - t.cx) * t.k)
            minY = min(minY, floor + (u.minY - t.bottom) * t.k)
            plan[g.slot] = t
        }
        guard !plan.isEmpty else { return (cell, content, 0) }

        let padX = max(-minX, maxX - cell.width, 0).rounded(.up), padT = max(-minY, 0).rounded(.up)
        let W = Int(cell.width + 2 * padX), H = Int(cell.height + padT)
        let nmw = max(24, W / 2), nmh = max(26, H / 2)
        // the frame's own colour space when it is RGB, so redrawn rows match the rest
        func rgb(_ img: CGImage) -> CGColorSpace {
            if let cs = img.colorSpace, cs.model == .rgb { return cs }
            return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        }
        // y down here, like the atlas; CoreGraphics draws y up, hence the flip
        func redo(_ img: CGImage, _ t: Grow?) -> (CGImage, Mask) {
            guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: rgb(img),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return (img, SpriteSheet.mask(img, w: nmw, h: nmh)) }
            ctx.interpolationQuality = pixelated ? .none : .high
            let k = t?.k ?? 1
            let x = padX + (t.map { mid - $0.cx * $0.k } ?? 0)
            let top = padT + (t.map { floor - $0.bottom * $0.k } ?? 0)
            let w = CGFloat(img.width) * k, h = CGFloat(img.height) * k
            ctx.draw(img, in: CGRect(x: x, y: CGFloat(H) - top - h, width: w, height: h))
            let out = ctx.makeImage() ?? img
            return (out, SpriteSheet.mask(out, w: nmw, h: nmh))
        }
        let moveAll = padX > 0 || padT > 0
        func remake(_ row: Row, _ t: Grow?) -> Row {
            var r = row
            for i in r.frames.indices {
                let (img, m) = redo(r.frames[i], t)
                r.frames[i] = img; r.masks[i] = m
            }
            return r
        }
        for c in Array(rows.keys) {
            let t = c == .idle ? nil : plan[Slot.row(c)]
            if t != nil || moveAll, let r = rows[c] { rows[c] = remake(r, t) }
        }
        for c in Array(intros.keys) {
            let t = plan[Slot.intro(c)]
            if t != nil || moveAll, let r = intros[c] { intros[c] = remake(r, t) }
        }
        if plan[Slot.look] != nil || moveAll {
            let t = plan[Slot.look]
            look = look.map { e -> (image: CGImage, mask: Mask) in
                let (img, m) = redo(e.image, t)
                return (image: img, mask: m)
            }
        }
        return (CGSize(width: W, height: H), content.offsetBy(dx: padX, dy: padT), plan.count)
    }

    /// A clip the atlas does not have borrows the closest one it does.
    func row(for clip: SpriteClip) -> Row? {
        let chain: [SpriteClip]
        switch clip {
        case .runLeft:  chain = [.runLeft, .runRight]
        case .review:   chain = [.review, .working]
        case .waiting:  chain = [.waiting, .waving]
        case .jumping:  chain = [.jumping, .waving]
        default:        chain = [clip]
        }
        for c in chain { if let r = rows[c] { return r } }
        return rows[.idle]
    }

    /// The frame to show for what the brain says, with its mask.
    func pick(_ f: PetFrame) -> (CGImage, Mask)? {
        let intro = intros[f.clip]
        let lead = intro?.durations.reduce(0, +) ?? 0
        if let i = f.look, look.count == 16 {
            let l = look[((i % 16) + 16) % 16]
            return (l.image, l.mask)
        }
        if let intro, f.clipAge < lead {
            // the one-shot lead-in, played once each time the row starts
            let k = intro.frame(at: f.clipAge)
            return (intro.frames[k], intro.masks[k])
        }
        guard let r = row(for: f.clip) else { return nil }
        // there is no sleeping row in the contract: she idles at a third of the pace
        let k = r.frame(at: (f.clipAge - lead) * (f.sleeping ? 0.35 : 1))
        return (r.frames[k], r.masks[k])
    }

    /// The largest block size every horizontal run of identical opaque pixels is a
    /// multiple of: the scale the drawing was blown up by. 1 for anything not pixel art.
    static func pixelBlock(_ img: CGImage) -> Int {
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w*h*4)
        buf.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        var g = 0
        for y in 0..<h {
            var run = 0
            for x in 0..<w {
                let i = (y*w + x) * 4
                let same = x > 0 && buf[i+3] > 0 && buf[i] == buf[i-4] && buf[i+1] == buf[i-3]
                    && buf[i+2] == buf[i-2] && buf[i+3] == buf[i-1]
                if same { run += 1; continue }
                if run > 0, buf[i-1] > 0 { g = gcd(g, run); if g == 1 { return 1 } }
                run = buf[i+3] > 0 ? 1 : 0
            }
            if run > 0 { g = gcd(g, run) }
        }
        return max(1, min(g, 16))
    }

    static func colorInfo(_ img: CGImage) -> (Bool, CGFloat) {
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w*h*4)
        buf.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var n = 0.0, sat = 0.0, hx = 0.0, hy = 0.0
        for i in stride(from: 0, to: buf.count, by: 4) where buf[i+3] >= 128 {
            let a = Double(buf[i+3]) / 255
            let r = Double(buf[i]) / 255 / a, g = Double(buf[i+1]) / 255 / a, b = Double(buf[i+2]) / 255 / a
            let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
            let s = mx == 0 ? 0 : d / mx
            n += 1; sat += s
            guard d >= 0.05 else { continue }
            var hh: Double
            if mx == r { hh = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { hh = (b - r) / d + 2 }
            else { hh = (r - g) / d + 4 }
            hh *= 60
            hx += cos(hh * .pi / 180) * s; hy += sin(hh * .pi / 180) * s
        }
        var hue = atan2(hy, hx) * 180 / .pi
        if hue < 0 { hue += 360 }
        return (n == 0 || sat / n < 0.12, CGFloat(hue))
    }

    private static let ci = CIContext(options: [.useSoftwareRenderer: false])

    /// The frame in another colour: hue turned for a coloured pet (a blue Mochi is still
    /// Mochi), colourised keeping the shading for a grey one.
    func tinted(_ img: CGImage, _ color: NSColor) -> CGImage? {
        let input = CIImage(cgImage: img)
        let filter: CIFilter?
        if gray {
            filter = CIFilter(name: "CIColorMonochrome", parameters: [
                kCIInputImageKey: input, kCIInputColorKey: CIColor(color: color) ?? CIColor(red: 1, green: 0, blue: 0),
                kCIInputIntensityKey: 0.7])
        } else {
            let target = (color.usingColorSpace(.sRGB)?.hueComponent ?? 0) * 360
            let angle = (target - hue) * .pi / 180
            filter = CIFilter(name: "CIHueAdjust", parameters: [kCIInputImageKey: input, kCIInputAngleKey: angle])
        }
        guard let out = filter?.outputImage else { return nil }
        return Self.ci.createCGImage(out, from: input.extent)
    }

    /// Renders a frame small and keeps only its alpha. Bitmap memory starts at the top
    /// row, so the result is y down like the atlas.
    static func mask(_ img: CGImage, w: Int, h: Int) -> Mask {
        var buf = [UInt8](repeating: 0, count: w*h*4)
        buf.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var a = [UInt8](repeating: 0, count: w*h)
        for i in 0..<(w*h) { a[i] = buf[i*4 + 3] }
        return Mask(w: w, h: h, data: a)
    }

    /// Pixel art has hard edges: almost no pixel is partly transparent. A painted or
    /// 3D-style pet has a soft rim all around. The manifest's `"pixelated"` wins.
    static func looksPixelated(_ img: CGImage) -> Bool {
        let m = mask(img, w: img.width, h: img.height)
        var solid = 0, soft = 0
        for a in m.data where a > 0 { if a > 15 && a < 240 { soft += 1 } else { solid += 1 } }
        return solid > 0 && Double(soft) / Double(solid + soft) < 0.015
    }
}

/// Plays a `SpriteSheet`. No rig and no transforms: one layer whose contents swap
/// between atlas cells, exactly the way Codex draws its pets.
final class SpriteView: PetCanvas {
    let sheet: SpriteSheet
    private let root = CALayer()
    private let sprite = CALayer()
    /// Points per atlas pixel.
    private let zoom: CGFloat
    private let petHeight: CGFloat
    private var shown: CGImage?
    private var shownMask: SpriteSheet.Mask?
    /// One pet per session: the colour this one is drawn in (nil = its own).
    var tint: NSColor? { didSet { tintCache.removeAll(); shown = nil } }
    private var tintCache: [ObjectIdentifier: CGImage] = [:]
    /// The frame on screen now and its mask, for whoever hosts this view.
    var currentMask: SpriteSheet.Mask? { shownMask }

    init(sheet: SpriteSheet, petHeight: CGFloat, backing: CGFloat = 2) {
        self.sheet = sheet
        self.petHeight = petHeight
        var z = petHeight / max(1, sheet.content.height)
        if sheet.pixelated {
            // one pixel of the drawing (a block of atlas pixels) has to be a whole number
            // of screen pixels, or the blocks come out uneven and shimmer while she moves
            let b = CGFloat(sheet.block) * backing
            z = max(1, (z * b).rounded()) / b
        }
        zoom = z
        super.init(frame: CGRect(x: 0, y: 0, width: sheet.cellSize.width*z, height: sheet.cellSize.height*z))
        layer = root
        wantsLayer = true
        root.masksToBounds = false
        sprite.frame = bounds
        sprite.contentsGravity = .resize
        sprite.magnificationFilter = sheet.pixelated ? .nearest : .trilinear
        sprite.minificationFilter = .trilinear
        root.addSublayer(sprite)
        render(PetFrame())
    }
    required init?(coder: NSCoder) { fatalError() }

    override var footInset: CGFloat { (sheet.cellSize.height - sheet.content.maxY) * zoom }
    override var headHeight: CGFloat { sheet.content.height * zoom }
    override var motionGrid: CGFloat { sheet.pixelated ? zoom : 0 }
    /// About half her own height per second: brisk, and the 8-frame run cycle (just
    /// over a second) still lands its steps roughly where the feet are.
    override var walkSpeed: CGFloat? { petHeight * 0.55 }
    override var snapsToBacking: Bool { sheet.pixelated }
    var hasTalk: Bool { sheet.rows[.talking] != nil }
    override var menubarIcon: NSImage? {
        guard let icon = sheet.icon else { return nil }
        return NSImage(cgImage: icon, size: NSSize(width: 18, height: 18))
    }

    override func render(_ f: PetFrame) {
        guard let picked = sheet.pick(f), picked.0 !== shown else { return }
        let (img, mask) = picked
        var drawn = img
        if let t = tint {
            let id = ObjectIdentifier(img)
            if let c = tintCache[id] { drawn = c }
            else if let c = sheet.tinted(img, t) { tintCache[id] = c; drawn = c }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.contents = drawn
        CATransaction.commit()
        shown = img
        shownMask = mask
    }

    override func hitsPet(_ local: CGPoint) -> Bool {
        guard let m = shownMask, bounds.width > 0, bounds.height > 0 else { return false }
        return m.opaque(nx: local.x / bounds.width, ny: 1 - local.y / bounds.height)
    }

    override func snapshot() -> CGImage? {
        let w = Int(bounds.width*2), h = Int(bounds.height*2)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.scaleBy(x: 2, y: 2)
        root.render(in: ctx)
        return ctx.makeImage()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let s = window?.backingScaleFactor ?? 2
        root.contentsScale = s
        sprite.contentsScale = s
    }
}
