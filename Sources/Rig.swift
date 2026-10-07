import AppKit

/// One cut-out piece of the figurine, positioned in the rig's canonical 334x472 space.
struct RigPart {
    let name: String
    let image: CGImage
    let rect: CGRect       // canonical coordinates, y down
    /// Pixel build only: the limb drawn at a set of fixed angles, all on this same
    /// rect. Turning a sprite at runtime tears it apart, so the turn is baked in.
    var spin: [(angle: CGFloat, image: CGImage)] = []

    func spun(_ deg: CGFloat) -> CGImage? {
        spin.min { abs($0.angle - deg) < abs($1.angle - deg) }?.image
    }
}

struct Rig {
    /// Where the layers came from; the menu bar icon (`menubar.png`) lives there too.
    let directory: URL
    let canonical: CGSize
    let content: CGRect
    let floor: CGFloat
    /// Canonical pixels per sprite pixel in the pixel-art build, 0 for the photo rig.
    /// Everything downstream keys off this: nearest-neighbour sampling, and snapping
    /// the canvas and the zoom so one sprite pixel is a whole number of screen pixels.
    let pixel: CGFloat
    let pivots: [String: CGPoint]
    var parts: [String: RigPart] = [:]
    let silhouette: (data: [UInt8], width: Int, height: Int)

    /// Back to front. Legs sit behind the shorts so the hip seam never shows.
    static let order = ["shadow", "legL", "legR", "body", "armL", "armR",
                        "head", "irisL", "irisR", "lidL", "lidR"]

    init?(directory: URL) {
        self.directory = directory
        guard let raw = try? Data(contentsOf: directory.appendingPathComponent("rig.json")),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let canon = json["canonical"] as? [Double],
              let cont = json["content"] as? [Double],
              let layers = json["layers"] as? [String: [String: Double]],
              let pv = json["pivots"] as? [String: [Double]],
              canon.count >= 2, cont.count >= 4 else { return nil }

        canonical = CGSize(width: canon[0], height: canon[1])
        content = CGRect(x: cont[0], y: cont[1], width: cont[2]-cont[0], height: cont[3]-cont[1])
        floor = json["floor"] as? Double ?? cont[3]
        pixel = CGFloat(json["pixel"] as? Double ?? 0)
        // well-typed but short is still broken: a pivot written as a single number
        // used to trap at launch instead of taking the failure path the caller has
        var points: [String: CGPoint] = [:]
        for (name, v) in pv {
            guard v.count >= 2 else { return nil }
            points[name] = CGPoint(x: v[0], y: v[1])
        }
        pivots = points

        for (name, info) in layers {
            let url = directory.appendingPathComponent("\(name).png")
            guard let x = info["x"], let y = info["y"],
                  let w = info["w"], let h = info["h"],
                  let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            parts[name] = RigPart(name: name, image: img,
                                  rect: CGRect(x: x, y: y, width: w, height: h))
        }
        for (name, angles) in (json["spin"] as? [String: [Double]]) ?? [:] {
            guard parts[name] != nil else { continue }
            parts[name]!.spin = angles.compactMap { a in
                let url = directory.appendingPathComponent("\(name)@\(Int(a)).png")
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
                return (CGFloat(a), img)
            }
        }
        guard parts["head"] != nil, parts["body"] != nil else { return nil }

        silhouette = Rig.makeSilhouette(parts: parts, content: content)
    }

    /// Coarse alpha map of the whole figure, used so clicks fall through empty pixels.
    private static func makeSilhouette(parts: [String: RigPart], content: CGRect)
        -> (data: [UInt8], width: Int, height: Int) {
        let sw = 84, sh = 118
        var buf = [UInt8](repeating: 0, count: sw*sh)
        let cs = CGColorSpaceCreateDeviceGray()
        buf.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(data: ptr.baseAddress, width: sw, height: sh,
                                      bitsPerComponent: 8, bytesPerRow: sw, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setFillColor(gray: 1, alpha: 1)
            let kx = CGFloat(sw)/content.width, ky = CGFloat(sh)/content.height
            for name in Rig.order where name != "shadow" {
                guard let p = parts[name] else { continue }
                let r = CGRect(x: (p.rect.minX - content.minX)*kx,
                               y: (content.maxY - p.rect.maxY)*ky,
                               width: p.rect.width*kx, height: p.rect.height*ky)
                ctx.fill(r.insetBy(dx: r.width*0.06, dy: r.height*0.06))
            }
        }
        return (buf, sw, sh)
    }

    /// `point` is normalised 0..1 across the content box, y down.
    func isOpaque(atNormalised point: CGPoint) -> Bool {
        let x = Int(point.x * CGFloat(silhouette.width))
        let y = Int((1 - point.y) * CGFloat(silhouette.height))
        guard x >= 0, y >= 0, x < silhouette.width, y < silhouette.height else { return false }
        return silhouette.data[y*silhouette.width + x] > 40
    }
}
