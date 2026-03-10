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
        alert.messageText     = "Railway Settings"
        alert.informativeText = "Generate a token at railway.app → Account Settings → Tokens.\nFind your Project ID in the project URL on railway.app."
        alert.addButton(withTitle: "Save & Connect")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 60))

        let tokenField = makeField(placeholder: "API token", y: 34, in: container)
        tokenField.stringValue = Config.readToken() ?? ""

        let projectField = makeField(placeholder: "Project ID", y: 4, in: container)
        projectField.stringValue = Config.readProjectID() ?? ""

        alert.accessoryView              = container
        alert.window.initialFirstResponder = tokenField
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let token     = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectID = projectField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !projectID.isEmpty else { return }

        do {
            try Config.save(token: token, projectID: projectID)
            onSave?()
        } catch {
            let err = NSAlert()
            err.messageText    = "Could not save settings"
            err.informativeText = error.localizedDescription
            err.runModal()
        }
    }

    private func makeField(placeholder: String, y: CGFloat, in view: NSView) -> PasteableTextField {
        let f = PasteableTextField(frame: NSRect(x: 0, y: y, width: 320, height: 24))
        f.placeholderString = placeholder
        f.font              = .monospacedSystemFont(ofSize: 12, weight: .regular)
        f.bezelStyle        = .roundedBezel
        view.addSubview(f)
        return f
    }
}
