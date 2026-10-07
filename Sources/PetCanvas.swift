import AppKit

/// The nine animation rows of the Codex pet atlas, in atlas order. The brain thinks in
/// these too, so any atlas pet - one of the hundreds made for Codex, or one you drew -
/// gets the same reactions as the built-in ones.
enum SpriteClip: Int, CaseIterable {
    case idle = 0, runRight, runLeft, waving, jumping, failed, waiting, working, review
    /// Not part of the Codex atlas: an optional extra strip (`"talkSheet"` in pet.json)
    /// that plays while a new line goes up in the balloon. Codex ignores the key, so a
    /// pet with it still works there.
    case talking = 100

    /// The names pet.json uses, which are the hatch-pet row names.
    init?(name: String) {
        switch name {
        case "idle": self = .idle
        case "running-right": self = .runRight
        case "running-left": self = .runLeft
        case "waving": self = .waving
        case "jumping": self = .jumping
        case "failed": self = .failed
        case "waiting": self = .waiting
        case "running": self = .working
        case "review": self = .review
        case "talking": self = .talking
        default: return nil
        }
    }
}

/// Everything a pet needs to draw one frame. The layered rig reads `pose`; an atlas
/// reads `clip`/`clipAge`/`look`. Each ignores what it cannot use.
struct PetFrame {
    var pose = Pose()
    var clip: SpriteClip = .idle
    /// Seconds since `clip` started, so a row always plays from its first frame.
    var clipAge: CFTimeInterval = 0
    /// One of 16 look directions, clockwise from straight up; nil looks ahead.
    var look: Int?
    var sleeping = false
}

/// What the app needs from a pet view, whatever is drawing it. A base class rather than
/// a protocol so the window code can hold either kind as a plain NSView.
class PetCanvas: NSView {
    /// Distance from the window's bottom edge up to the soles, in points.
    var footInset: CGFloat { 0 }
    /// From the soles to the top of the head, in points: where the balloon goes.
    var headHeight: CGFloat { bounds.height }
    /// Steps the window moves in, in points. 0 means one backing pixel. Pixel art
    /// has to move a whole sprite pixel at a time or it shimmers.
    var motionGrid: CGFloat { 0 }
    /// Walking speed in points per second, or nil to let the brain derive it from
    /// the rig's stride.
    var walkSpeed: CGFloat? { nil }
    /// Canonical rig pixels to points, and canonical pixels per sprite cell. Only the
    /// layered rig has these; the brain sizes its motion with them.
    var rigScale: CGFloat { 0.14 }
    var rigCell: CGFloat { 0 }
    /// True when the view snapped itself to one screen's pixel density and has to be
    /// rebuilt on a screen with another one.
    var snapsToBacking: Bool { false }
    /// The menu bar icon for this pet.
    var menubarIcon: NSImage? { nil }

    func render(_ frame: PetFrame) {}
    /// True when the point (in this view's own coordinates) lands on the pet itself
    /// rather than on the transparent margin, so clicks elsewhere fall through.
    func hitsPet(_ local: CGPoint) -> Bool { false }
    /// Off-screen snapshot of the live layer tree, used for animation QA.
    func snapshot() -> CGImage? { nil }
}
