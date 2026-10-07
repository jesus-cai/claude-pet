import CoreGraphics

/// Everything the animator can move. Angles in degrees, offsets in canonical pixels.
struct Pose {
    var facing: CGFloat = 1          // +1 right, -1 mirrored

    var rootDX: CGFloat = 0
    var rootDY: CGFloat = 0          // negative = airborne

    var bodyRot: CGFloat = 0
    var bodyScaleX: CGFloat = 1
    var bodyScaleY: CGFloat = 1
    var bodyDY: CGFloat = 0

    var headRot: CGFloat = 0
    var headDX: CGFloat = 0
    var headDY: CGFloat = 0
    var headSquashX: CGFloat = 1

    var armLRot: CGFloat = 0
    var armRRot: CGFloat = 0
    var legLRot: CGFloat = 0
    var legRRot: CGFloat = 0

    var irisDX: CGFloat = 0
    var irisDY: CGFloat = 0
    var lidOpacity: CGFloat = 0

    var shadowScale: CGFloat = 1
    var shadowOpacity: CGFloat = 1

    /// Cross-fade between two poses. Used to ease state changes: without it a switch
    /// snaps every joint in a single frame, which reads as a glitch rather than as a
    /// move. `facing` is not blended - a mirror can't be half-applied.
    static func mix(_ a: Pose, _ b: Pose, _ k: CGFloat) -> Pose {
        func m(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x)*k }
        var p = Pose()
        p.facing = b.facing
        p.rootDX = m(a.rootDX, b.rootDX);           p.rootDY = m(a.rootDY, b.rootDY)
        p.bodyRot = m(a.bodyRot, b.bodyRot);        p.bodyDY = m(a.bodyDY, b.bodyDY)
        p.bodyScaleX = m(a.bodyScaleX, b.bodyScaleX); p.bodyScaleY = m(a.bodyScaleY, b.bodyScaleY)
        p.headRot = m(a.headRot, b.headRot);        p.headDX = m(a.headDX, b.headDX)
        p.headDY = m(a.headDY, b.headDY);           p.headSquashX = m(a.headSquashX, b.headSquashX)
        p.armLRot = m(a.armLRot, b.armLRot);        p.armRRot = m(a.armRRot, b.armRRot)
        p.legLRot = m(a.legLRot, b.legLRot);        p.legRRot = m(a.legRRot, b.legRRot)
        p.irisDX = m(a.irisDX, b.irisDX);           p.irisDY = m(a.irisDY, b.irisDY)
        p.lidOpacity = m(a.lidOpacity, b.lidOpacity)
        p.shadowScale = m(a.shadowScale, b.shadowScale)
        p.shadowOpacity = m(a.shadowOpacity, b.shadowOpacity)
        return p
    }
}
