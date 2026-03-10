import AppKit

enum LEDColor: Equatable {
    case green   // SUCCESS
    case yellow  // WAITING / QUEUED
    case blue    // BUILDING / DEPLOYING
    case red     // FAILED / CRASHED
    case gray    // UNKNOWN

    init(status: String) {
        switch status.uppercased() {
        case "SUCCESS":                                          self = .green
        case "WAITING", "QUEUED":                               self = .yellow
        case "BUILDING", "DEPLOYING", "INITIALIZING", "RESTARTING": self = .blue
        case "FAILED", "CRASHED", "ERROR":                      self = .red
        default:                                                self = .gray
        }
    }

    var nsColor: NSColor {
        switch self {
        case .green:  return NSColor(red: 0.00, green: 0.82, blue: 0.20, alpha: 1)
        case .yellow: return NSColor(red: 0.98, green: 0.75, blue: 0.00, alpha: 1)
        case .blue:   return NSColor(red: 0.15, green: 0.50, blue: 1.00, alpha: 1)
        case .red:    return NSColor(red: 0.95, green: 0.10, blue: 0.10, alpha: 1)
        case .gray:   return NSColor(red: 0.22, green: 0.22, blue: 0.22, alpha: 1)
        }
    }

    var label: String {
        switch self {
        case .green:  return "OK"
        case .yellow: return "QUEUED"
        case .blue:   return "DEPLOYING"
        case .red:    return "DOWN"
        case .gray:   return "—"
        }
    }
}

struct LEDView {
    static func render(colors: [LEDColor]) -> NSImage {
        let led: CGFloat  = 8   // even number → y is always an integer
        let gap: CGFloat  = 3
        let pad: CGFloat  = 4
        let barH: CGFloat = 22  // (22 - 8) / 2 = 7.0 exactly

        let n = CGFloat(colors.count)
        let w = pad * 2 + n * led + max(0, n - 1) * gap
        let size = NSSize(width: w, height: barH)

        // Drawing handler redraws at the correct Retina scale automatically.
        let img = NSImage(size: size, flipped: false) { _ in
            NSColor.clear.setFill()
            NSRect(origin: .zero, size: size).fill()

            let y = (barH - led) / 2   // = 7.0
            for (i, color) in colors.enumerated() {
                let x = pad + CGFloat(i) * (led + gap)
                color.nsColor.setFill()
                NSRect(x: x, y: y, width: led, height: led).fill()
            }
            return true
        }
        img.isTemplate = false
        return img
    }
}
