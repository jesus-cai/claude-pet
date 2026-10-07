import AppKit
import UserNotifications

/// The parts of a notice that reach you without looking at her: a sound, a system
/// notification, and a coloured dot on the menu bar icon. The balloon is the main
/// channel; these are for when she is behind a window or on another screen.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var sound = true
    var banners = false {
        didSet { if banners && !oldValue { requestPermission() } }
    }
    private var lastSound: CFTimeInterval = -10

    /// Notifications need a real bundle; run as a bare binary (debugging from the
    /// terminal) the center throws, so it is only touched from a .app.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
    }

    override init() {
        super.init()
        center?.delegate = self
    }

    private func requestPermission() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func alert(_ e: ClaudeEvent) {
        let now = CACurrentMediaTime()
        if sound, now - lastSound > 3 {
            lastSound = now
            let name: String
            switch e.kind {
            case .finished: name = "Glass"
            case .needsYou: name = "Ping"
            case .failed:   name = "Basso"
            default:        name = ""
            }
            if !name.isEmpty { NSSound(named: NSSound.Name(name))?.play() }
        }
        guard banners, let center else { return }
        let c = UNMutableNotificationContent()
        let where_ = e.project.isEmpty ? "Claude" : e.project
        switch e.kind {
        case .finished: c.title = "\(where_): listo"; c.body = e.detail.isEmpty ? "Claude terminó de responder." : e.detail
        case .failed:   c.title = "\(where_): error"; c.body = e.detail.isEmpty || e.detail == "api" ? "El turno terminó con un error." : e.detail
        case .needsYou: c.title = "\(where_): te necesita"; c.body = Self.ask(e.detail)
        default: return
        }
        // one notification per session: a new one replaces the old instead of piling up
        let req = UNNotificationRequest(identifier: "compa-\(e.session)", content: c, trigger: nil)
        center.add(req)
    }

    private static func ask(_ d: String) -> String {
        switch d {
        case "question": return "Tiene una pregunta."
        case "plan", "plan first": return "Quiere que apruebes un plan."
        case "", "permission", "input": return "Está esperando tu respuesta."
        default: return "¿Le dejas \(d)?"
        }
    }

    // Accessory apps count as "in front" surprisingly often; show the banner anyway.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list])
    }

    /// The menu bar icon with a dot in the corner: orange waiting, green done, red
    /// error. A template-free copy, since the icon is the pet's own face.
    static func badged(_ base: NSImage?, _ color: NSColor?) -> NSImage? {
        guard let base else { return nil }
        guard let color else { return base }
        let size = NSSize(width: 18, height: 18)
        return NSImage(size: size, flipped: false) { r in
            base.draw(in: r)
            let d: CGFloat = 7
            let dot = NSRect(x: r.maxX - d, y: r.maxY - d, width: d, height: d)
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(ovalIn: dot.insetBy(dx: -1, dy: -1)).fill()
            color.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
    }
}
