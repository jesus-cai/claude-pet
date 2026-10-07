import AppKit

/// Who is who with one pet per session: which pet and which colour each session gets.
/// Stable - a project always gets the same, unless you pin it - and two live sessions
/// never repeat while there is choice left. Same algorithm (and hash) as the Windows
/// version, so a project looks the same on both.
enum Assign {
    struct Color { let id: String; let name: String; let hex: String
        var ns: NSColor {
            let v = Int(hex.dropFirst(), radix: 16) ?? 0
            return NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255,
                           blue: CGFloat(v & 255) / 255, alpha: 1)
        }
    }
    static let palette: [Color] = [
        Color(id: "coral", name: "Coral", hex: "#ff6b5e"), Color(id: "ambar", name: "Ámbar", hex: "#ffb02e"),
        Color(id: "verde", name: "Verde", hex: "#4cc764"), Color(id: "turquesa", name: "Turquesa", hex: "#2ec4b6"),
        Color(id: "azul", name: "Azul", hex: "#4a8cff"), Color(id: "violeta", name: "Violeta", hex: "#9b6bff"),
        Color(id: "rosa", name: "Rosa", hex: "#ff6fb5"), Color(id: "oliva", name: "Oliva", hex: "#9aa63a"),
    ]

    enum By: String { case pet, color, mix }
    struct Pin { var pet: String?; var color: Int? }
    struct Result: Equatable { var pet: String; var color: Int; var tint: Bool; var label: String }

    /// FNV-1a over the Unicode scalars, like the JS version over code points.
    static func hash(_ s: String) -> UInt32 {
        var h: UInt32 = 0x811c9dc5
        for u in s.unicodeScalars { h ^= u.value; h = h &* 0x01000193 }
        return h
    }

    private static func probe(_ n: Int, _ start: UInt32, _ taken: Set<Int>) -> Int {
        guard n > 0 else { return 0 }
        for i in 0..<n { let k = Int((UInt64(start) + UInt64(i)) % UInt64(n)); if !taken.contains(k) { return k } }
        return Int(UInt64(start) % UInt64(n))
    }

    static func assign(_ sessions: [(key: String, project: String)], by: By, rotation rot: [String], mainPet: String,
                       pins: [String: Pin], keep: [String: Result]) -> [String: Result] {
        let rotation = rot.isEmpty ? [mainPet] : rot
        var out: [String: Result] = [:]
        var petsTaken = Set<Int>(), colorsTaken = Set<Int>(), usedPet: [String: Int] = [:]
        for s in sessions {
            let pin = pins[s.project] ?? Pin()
            let prev = keep[s.key]
            let name = s.project.isEmpty ? s.key : s.project
            let pet: String
            if let p = prev, (rotation + [mainPet]).contains(p.pet), pin.pet == nil { pet = p.pet }
            else if let p = pin.pet { pet = p }
            else if by == .color { pet = mainPet }
            else { pet = rotation[probe(rotation.count, hash(name), petsTaken)] }
            if let i = rotation.firstIndex(of: pet) { petsTaken.insert(i) }
            let color: Int
            if let p = prev, pin.color == nil { color = p.color }
            else if let c = pin.color { color = c }
            else { color = probe(palette.count, hash("c:" + name), colorsTaken) }
            colorsTaken.insert(color)
            usedPet[pet, default: 0] += 1
            // the sprite is tinted with 'color' and 'mix'; with 'pet' only when it repeats
            let tint = by != .pet || usedPet[pet]! > 1 || pin.color != nil
            out[s.key] = Result(pet: pet, color: color, tint: tint, label: s.project.isEmpty ? "Claude" : s.project)
        }
        var seen: [String: Int] = [:]
        for s in sessions {
            guard var r = out[s.key] else { continue }
            let n = (seen[r.label] ?? 0) + 1
            seen[r.label] = n
            if n > 1 { r.label = "\(r.label) · \(n)"; out[s.key] = r }
        }
        return out
    }
}
