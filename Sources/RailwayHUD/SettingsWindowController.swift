import AppKit

private enum SettingsPalette {
    static let canvas = NSColor(calibratedRed: 0.04, green: 0.05, blue: 0.07, alpha: 1)
    static let chrome = NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.10, alpha: 0.98)
    static let line = NSColor(calibratedWhite: 0.16, alpha: 1)
    static let text = NSColor(calibratedWhite: 0.88, alpha: 1)
    static let muted = NSColor(calibratedWhite: 0.55, alpha: 1)
    static let subtle = NSColor(calibratedWhite: 0.38, alpha: 1)
    static let success = NSColor(calibratedRed: 0.00, green: 0.82, blue: 0.20, alpha: 1)
}

final class SettingsWindowController: NSObject {
    var onConfigurationChange: (() -> Void)?
    var onConnectRequested: (() -> Void)?

    private let api = RailwayAPI()

    private var window: NSWindow?
    private var sessionBadge: SettingsStatusBadge?
    private var connectButton: SettingsActionButton?
    private var projectSection: NSView?
    private var projectDropdown: SettingsDropdownButton?
    private var fetchButton: SettingsActionButton?
    private var saveButton: SettingsActionButton?
    private var selectionLabel: NSTextField?
    private var projects: [ProjectInfo] = []

    func show() {
        if window == nil { buildWindow() }
        updateUI()
        if Config.hasOAuthSession() { fetchProjects() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Actions

    @objc private func handleConnect() {
        if Config.hasOAuthSession() {
            Config.clearOAuthTokens()
            Config.clearProjectID()
            projects = []
            onConfigurationChange?()
        }
        updateUI()
        onConnectRequested?()
    }

    @objc private func fetchProjects() {
        guard Config.hasOAuthSession() else { return }
        projectDropdown?.setItems([])
        projectDropdown?.placeholder = "Loading..."
        selectionLabel?.stringValue = "loading..."
        updateSaveButtonState()

        api.fetchProjects { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }

                switch result {
                case .success(let projects):
                    self.projects = projects
                    self.projectDropdown?.placeholder = "Select project..."
                    self.projectDropdown?.setItems(projects.map { ($0.name, $0.id) })

                    if let savedProjectID = Config.readProjectID(),
                       let index = projects.firstIndex(where: { $0.id == savedProjectID }) {
                        self.projectDropdown?.selectedID = projects[index].id
                    } else {
                        self.projectDropdown?.selectedID = nil
                    }

                case .failure(let error):
                    self.projects = []
                    self.projectDropdown?.setItems([])
                    if let apiError = error as? APIError,
                       apiError.isSignInRequired {
                        self.projectDropdown?.placeholder = "Sign in to browse"
                    } else {
                        self.projectDropdown?.placeholder = "Unavailable"
                    }
                    self.projectDropdown?.selectedID = nil
                    self.selectionLabel?.stringValue = error.localizedDescription
                }

                if !Config.hasOAuthSession() {
                    self.updateUI()
                }
                self.updateSelectionLabel()
                self.updateSaveButtonState()
            }
        }
    }

    @objc private func save() {
        guard Config.hasOAuthSession() else {
            showError("Please sign in with Railway first.")
            return
        }

        let projectID = projectDropdown?.selectedID ?? ""
        guard !projectID.isEmpty else {
            showError("Please select a project.")
            return
        }

        Config.saveProjectID(projectID)
        onConfigurationChange?()
        window?.close()
    }

    @objc private func cancel() {
        window?.close()
    }

    @objc private func projectSelectionChanged() {
        updateSelectionLabel()
        updateSaveButtonState()
    }

    // MARK: - Layout

    private func buildWindow() {
        let panelSize = NSSize(width: 448, height: 236)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Railway HUD Settings"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = SettingsPalette.chrome
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hasShadow = true
        panel.center()
        panel.isReleasedWhenClosed = false

        let content = SettingsCanvasView(frame: NSRect(origin: .zero, size: panelSize))
        content.autoresizingMask = [.width, .height]
        panel.contentView = content

        let pad: CGFloat = 18
        let width = panelSize.width - (pad * 2)

        let eyebrow = makeLabel(
            "RAILWAY HUD // CONTROL PLANE",
            frame: NSRect(x: pad, y: panelSize.height - 36, width: width, height: 12),
            color: SettingsPalette.muted,
            weight: .semibold,
            size: 10
        )
        content.addSubview(eyebrow)
        content.addSubview(makeRule(frame: NSRect(x: pad, y: panelSize.height - 48, width: width, height: 1)))

        let sessionSection = NSView(frame: NSRect(x: pad, y: 122, width: width, height: 38))
        content.addSubview(sessionSection)

        sessionSection.addSubview(makeLabel(
            "SESSION",
            frame: NSRect(x: 0, y: 24, width: 100, height: 12),
            color: SettingsPalette.muted,
            weight: .semibold,
            size: 11
        ))

        let badge = SettingsStatusBadge(frame: NSRect(x: 0, y: 0, width: 188, height: 16))
        sessionSection.addSubview(badge)
        sessionBadge = badge

        let connectButton = SettingsActionButton(
            frame: NSRect(x: width - 92, y: -1, width: 92, height: 20),
            style: .secondary
        )
        connectButton.target = self
        connectButton.action = #selector(handleConnect)
        sessionSection.addSubview(connectButton)
        self.connectButton = connectButton

        content.addSubview(makeRule(frame: NSRect(x: pad, y: 108, width: width, height: 1)))

        let projectSection = NSView(frame: NSRect(x: pad, y: 56, width: width, height: 48))
        content.addSubview(projectSection)
        self.projectSection = projectSection

        projectSection.addSubview(makeLabel(
            "PROJECT",
            frame: NSRect(x: 0, y: 34, width: 100, height: 12),
            color: SettingsPalette.muted,
            weight: .semibold,
            size: 11
        ))

        let dropdown = SettingsDropdownButton(frame: NSRect(x: 0, y: 0, width: width - 74, height: 28))
        dropdown.placeholder = "Sign in to browse"
        dropdown.target = self
        dropdown.action = #selector(projectSelectionChanged)
        projectSection.addSubview(dropdown)
        projectDropdown = dropdown

        let fetchButton = SettingsActionButton(
            frame: NSRect(x: width - 56, y: 4, width: 56, height: 20),
            style: .secondary
        )
        fetchButton.title = "REFRESH"
        fetchButton.target = self
        fetchButton.action = #selector(fetchProjects)
        projectSection.addSubview(fetchButton)
        self.fetchButton = fetchButton

        let selectionLabel = makeLabel(
            "select a project",
            frame: NSRect(x: pad, y: 24, width: width - 100, height: 12),
            color: SettingsPalette.subtle,
            weight: .regular,
            size: 10
        )
        content.addSubview(selectionLabel)
        self.selectionLabel = selectionLabel

        let cancelButton = SettingsActionButton(
            frame: NSRect(x: panelSize.width - pad - 92, y: 26, width: 48, height: 20),
            style: .secondary
        )
        cancelButton.title = "CANCEL"
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        content.addSubview(cancelButton)

        let saveButton = SettingsActionButton(
            frame: NSRect(x: panelSize.width - pad - 36, y: 26, width: 36, height: 20),
            style: .primary
        )
        saveButton.title = "SAVE"
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(save)
        content.addSubview(saveButton)
        self.saveButton = saveButton

        window = panel
    }

    // MARK: - State

    private func updateUI() {
        let isConnected = Config.hasOAuthSession()
        sessionBadge?.setStatus(
            text: isConnected ? "SESSION ACTIVE" : "SIGN-IN REQUIRED",
            color: isConnected ? SettingsPalette.success : SettingsPalette.subtle
        )

        connectButton?.title = isConnected ? "REAUTH" : "CONNECT"
        connectButton?.style = .secondary

        projectSection?.alphaValue = isConnected ? 1 : 0.42
        projectDropdown?.isEnabled = isConnected
        fetchButton?.isEnabled = isConnected

        if !isConnected {
            projects = []
            projectDropdown?.setItems([])
            projectDropdown?.placeholder = "Sign in to browse"
            projectDropdown?.selectedID = nil
        }

        updateSelectionLabel()
        updateSaveButtonState()
    }

    private func updateSelectionLabel() {
        guard Config.hasOAuthSession() else {
            selectionLabel?.stringValue = "sign in required"
            return
        }

        if let projectID = Config.readProjectID(),
           !projectID.isEmpty,
           let name = projects.first(where: { $0.id == projectID })?.name {
            selectionLabel?.stringValue = "saved: \(name)"
            return
        }

        if let name = currentSelectionName {
            selectionLabel?.stringValue = "selected: \(name)"
            return
        }

        selectionLabel?.stringValue = projects.isEmpty ? "no project" : "select a project"
    }

    private var currentSelectionName: String? {
        guard let projectID = projectDropdown?.selectedID,
              !projectID.isEmpty else { return nil }
        return projects.first(where: { $0.id == projectID })?.name
    }

    private func updateSaveButtonState() {
        let selectedProjectID = projectDropdown?.selectedID
        saveButton?.isEnabled = Config.hasOAuthSession() && !(selectedProjectID?.isEmpty ?? true)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Could not save settings"
        alert.informativeText = message
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    private func makeLabel(
        _ text: String,
        frame: NSRect,
        color: NSColor,
        weight: NSFont.Weight,
        size: CGFloat
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.frame = frame
        return label
    }

    private func makeRule(frame: NSRect) -> NSView {
        let line = NSView(frame: frame)
        line.wantsLayer = true
        line.layer?.backgroundColor = SettingsPalette.line.cgColor
        return line
    }
}

private final class SettingsCanvasView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        SettingsPalette.canvas.setFill()
        bounds.fill()

        let gradient = NSGradient(colors: [
            SettingsPalette.chrome.withAlphaComponent(0.92),
            SettingsPalette.canvas
        ])
        gradient?.draw(in: NSBezierPath(rect: bounds), angle: 125)

        NSColor.white.withAlphaComponent(0.03).setStroke()
        let grid = NSBezierPath()
        stride(from: CGFloat(0), through: bounds.height, by: 24).forEach { y in
            grid.move(to: NSPoint(x: 0, y: y))
            grid.line(to: NSPoint(x: bounds.width, y: y))
        }
        grid.lineWidth = 1
        grid.stroke()
    }
}

private final class SettingsStatusBadge: NSView {
    private let dot = NSView(frame: NSRect(x: 0, y: 4, width: 8, height: 8))
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        addSubview(dot)

        label.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        label.frame = NSRect(x: 18, y: 1, width: frameRect.width - 18, height: 14)
        addSubview(label)
    }

    func setStatus(text: String, color: NSColor) {
        label.stringValue = text
        label.textColor = color
        dot.layer?.backgroundColor = color.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class SettingsActionButton: NSButton {
    enum Style {
        case primary
        case secondary
    }

    var style: Style = .secondary {
        didSet { refreshAppearance() }
    }

    override var title: String {
        didSet { refreshAppearance() }
    }

    override var isEnabled: Bool {
        didSet { refreshAppearance() }
    }

    init(frame frameRect: NSRect, style: Style) {
        self.style = style
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        refreshAppearance()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshAppearance()
    }

    private func refreshAppearance() {
        let color: NSColor
        switch (style, isEnabled) {
        case (.primary, true):
            color = SettingsPalette.success
        case (.primary, false):
            color = SettingsPalette.subtle
        case (.secondary, true):
            color = SettingsPalette.text
        case (.secondary, false):
            color = SettingsPalette.subtle
        }

        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: color
            ]
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class SettingsDropdownButton: NSButton {
    var placeholder: String = "" {
        didSet { needsDisplay = true }
    }

    var selectedID: String? {
        didSet { needsDisplay = true }
    }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    private var items: [(title: String, id: String)] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
    }

    func setItems(_ items: [(String, String)]) {
        self.items = items
        if let selectedID, !items.contains(where: { $0.1 == selectedID }) {
            self.selectedID = nil
        } else {
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }

        let menu = NSMenu()
        for item in items {
            let menuItem = NSMenuItem(title: item.title, action: #selector(selectItem(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item.id
            menuItem.state = item.id == selectedID ? .on : .off
            menu.addItem(menuItem)
        }

        if menu.items.isEmpty {
            let menuItem = NSMenuItem(title: placeholder, action: nil, keyEquivalent: "")
            menuItem.isEnabled = false
            menu.addItem(menuItem)
        }

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 2), in: self)
    }

    @objc private func selectItem(_ sender: NSMenuItem) {
        selectedID = sender.representedObject as? String
        if let target, let action {
            NSApp.sendAction(action, to: target, from: self)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = isEnabled
            ? NSColor(calibratedRed: 0.11, green: 0.13, blue: 0.17, alpha: 0.96)
            : NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.13, alpha: 0.60)
        background.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()

        let borderColor = isEnabled ? SettingsPalette.line : SettingsPalette.subtle.withAlphaComponent(0.3)
        borderColor.setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        border.lineWidth = 1
        border.stroke()

        let dividerX = bounds.width - 30.5
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: dividerX, y: 6))
        divider.line(to: NSPoint(x: dividerX, y: bounds.height - 6))
        (isEnabled ? SettingsPalette.line : SettingsPalette.subtle.withAlphaComponent(0.3)).setStroke()
        divider.lineWidth = 1
        divider.stroke()

        let title = items.first(where: { $0.id == selectedID })?.title ?? placeholder
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: isEnabled ? SettingsPalette.text : SettingsPalette.muted
        ]
        let titleRect = NSRect(x: 14, y: 5, width: bounds.width - 52, height: 18)
        title.draw(in: titleRect, withAttributes: attrs)

        let chevronColor = isEnabled ? SettingsPalette.muted : SettingsPalette.subtle
        chevronColor.setStroke()

        let up = NSBezierPath()
        up.move(to: NSPoint(x: bounds.width - 20, y: 18))
        up.line(to: NSPoint(x: bounds.width - 15, y: 23))
        up.line(to: NSPoint(x: bounds.width - 10, y: 18))
        up.lineWidth = 1.5
        up.lineJoinStyle = .round
        up.lineCapStyle = .round
        up.stroke()

        let down = NSBezierPath()
        down.move(to: NSPoint(x: bounds.width - 20, y: 10))
        down.line(to: NSPoint(x: bounds.width - 15, y: 5))
        down.line(to: NSPoint(x: bounds.width - 10, y: 10))
        down.lineWidth = 1.5
        down.lineJoinStyle = .round
        down.lineCapStyle = .round
        down.stroke()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
