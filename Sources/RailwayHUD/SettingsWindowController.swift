import AppKit

class PasteableTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "v": return NSApp.sendAction(#selector(NSText.paste(_:)),          to: nil, from: self)
        case "c": return NSApp.sendAction(#selector(NSText.copy(_:)),           to: nil, from: self)
        case "x": return NSApp.sendAction(#selector(NSText.cut(_:)),            to: nil, from: self)
        case "a": return NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: self)
        case "z": return NSApp.sendAction(Selector(("undo:")),                  to: nil, from: self)
        default:  return super.performKeyEquivalent(with: event)
        }
    }
}

class SettingsWindowController {
    var onSave: (() -> Void)?

    func show() {
        let alert = NSAlert()
        alert.messageText    = "Railway API Token"
        alert.informativeText = "Generate one at railway.com → Account Settings → Tokens"
        alert.addButton(withTitle: "Save & Connect")
        alert.addButton(withTitle: "Cancel")

        let field = PasteableTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "Paste your token here…"
        field.font              = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.bezelStyle        = .roundedBezel
        field.stringValue       = Config.readToken() ?? ""

        alert.accessoryView              = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let token = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }

        do {
            try "RAILWAY_TOKEN=\(token)\n".write(toFile: Config.tokenFile, atomically: true, encoding: .utf8)
            onSave?()
        } catch {
            let err = NSAlert()
            err.messageText    = "Could not save token"
            err.informativeText = error.localizedDescription
            err.runModal()
        }
    }
}
