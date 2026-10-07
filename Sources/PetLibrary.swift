import AppKit

/// One pet she can be. Either a Codex atlas (the standard: `pet.json` +
/// `spritesheet.webp`) or a layered rig (the old Chihiro format: cut-out parts with
/// pivots, animated live).
struct PetEntry {
    enum Kind {
        case atlas(sheet: URL, version: Int, pixelated: Bool?, talk: URL?, talkMs: Int,
                   intros: [String: URL], introMs: Int)
        case rig(photo: URL?, pixel: URL?)
    }
    let id: String
    let name: String
    let folder: URL
    let kind: Kind
    /// Where it was found, for the menu.
    let origin: String
    /// Personality, from pet.json. `reactions` picks the atlas row for a moment
    /// ("done", "drag", "wave", "error", "work" → "idle", "waving", "jumping",
    /// "failed", "waiting", "running", "review", "talking"); `lines` replaces what
    /// she says ("start", "done", "error"). Both optional.
    var reactions: [String: String] = [:]
    var lines: [String: [String]] = [:]

    var hasPixelVariant: Bool {
        if case .rig(let photo, let pixel) = kind { return photo != nil && pixel != nil }
        return false
    }
}

/// Finds pets. Folders are searched in order and the first pet with a given id wins,
/// so a copy in your own folder overrides the bundled one of the same name.
///
///   ~/.compa/pets/<id>/      yours
///   ~/.codex/pets/<id>/      the ones you already installed for Codex (petdex, hatch-pet...)
///   Compa.app/…/pets/<id>/   the ones that ship with the app
enum PetLibrary {
    static var home: URL {
        if let p = ProcessInfo.processInfo.environment["COMPA_HOME"], !p.isEmpty {
            return URL(fileURLWithPath: p)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".compa")
    }
    static var userPets: URL { home.appendingPathComponent("pets") }
    static var codexPets: URL {
        let env = ProcessInfo.processInfo.environment["CODEX_HOME"]
        let base = env.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return base.appendingPathComponent("pets")
    }
    static var bundledPets: URL? { Bundle.main.resourceURL?.appendingPathComponent("pets") }

    static func scan() -> [PetEntry] {
        var roots: [(URL, String)] = [(userPets, "tuya"), (codexPets, "Codex")]
        if let b = bundledPets { roots.append((b, "incluida")) }
        var seen = Set<String>()
        var out: [PetEntry] = []
        let fm = FileManager.default
        for (dir, origin) in roots {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else { continue }
            for f in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard (try? f.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      let e = entry(at: f, origin: origin), !seen.contains(e.id) else { continue }
                seen.insert(e.id)
                out.append(e)
            }
        }
        return out
    }

    static func entry(at folder: URL, origin: String) -> PetEntry? {
        let fm = FileManager.default
        func exists(_ u: URL?) -> URL? { u.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil } }

        var meta: [String: Any] = [:]
        if let d = try? Data(contentsOf: folder.appendingPathComponent("pet.json")),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { meta = j }
        let rawID = (meta["id"] as? String) ?? ""
        let id = rawID.isEmpty ? folder.lastPathComponent : rawID
        let name = (meta["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id

        if (meta["kind"] as? String) == "rig" {
            func dir(_ key: String) -> URL? {
                guard let s = meta[key] as? String else { return nil }
                return exists(folder.appendingPathComponent(s).appendingPathComponent("rig.json"))?
                    .deletingLastPathComponent()
            }
            let photo = dir("layers"), pixel = dir("pixelLayers")
            guard photo != nil || pixel != nil else { return nil }
            return PetEntry(id: id, name: name, folder: folder, kind: .rig(photo: photo, pixel: pixel), origin: origin,
                            reactions: meta["reactions"] as? [String: String] ?? [:],
                            lines: meta["lines"] as? [String: [String]] ?? [:])
        }

        var sheet = (meta["spritesheetPath"] as? String).flatMap { exists(folder.appendingPathComponent($0)) }
        if sheet == nil {
            sheet = ["spritesheet.webp", "spritesheet.png"].lazy
                .compactMap { exists(folder.appendingPathComponent($0)) }.first
        }
        guard let s = sheet else { return nil }
        let version = (meta["spriteVersionNumber"] as? NSNumber)?.intValue ?? 1
        return PetEntry(id: id, name: name, folder: folder,
                        kind: .atlas(sheet: s, version: version, pixelated: meta["pixelated"] as? Bool,
                                     talk: (meta["talkSheet"] as? String).flatMap { exists(folder.appendingPathComponent($0)) },
                                     talkMs: (meta["talkFrameMs"] as? NSNumber)?.intValue ?? 110,
                                     intros: ((meta["introSheets"] as? [String: String]) ?? [:])
                                        .compactMapValues { exists(folder.appendingPathComponent($0)) },
                                     introMs: (meta["introFrameMs"] as? NSNumber)?.intValue ?? 140),
                        origin: origin,
                        reactions: meta["reactions"] as? [String: String] ?? [:],
                        lines: meta["lines"] as? [String: [String]] ?? [:])
    }

    /// Builds the view for a pet, or nil when its files are broken.
    static func makeCanvas(_ e: PetEntry, petHeight: CGFloat, backing: CGFloat, preferPixels: Bool) -> PetCanvas? {
        switch e.kind {
        case .atlas(let url, let version, let pixelated, let talk, let talkMs, let intros, let introMs):
            guard let sheet = SpriteSheet(url: url, version: version, pixelated: pixelated,
                                          talk: talk, talkMs: talkMs,
                                          intros: intros, introMs: introMs) else { return nil }
            return SpriteView(sheet: sheet, petHeight: petHeight, backing: backing)
        case .rig(let photo, let pixel):
            let first = preferPixels ? (pixel ?? photo) : (photo ?? pixel)
            guard let dir = first, let rig = Rig(directory: dir) else { return nil }
            return PetView(rig: rig, petHeight: petHeight, backing: backing)
        }
    }
}
