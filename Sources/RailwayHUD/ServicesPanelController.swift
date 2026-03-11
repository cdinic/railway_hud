import AppKit

private let kDragType = NSPasteboard.PasteboardType("com.local.railway-hud.row")

// Layout constants
private let kW:      CGFloat = 264  // panel width
private let kRowH:   CGFloat = 26   // service row height
private let kFooterH: CGFloat = 52  // footer: one button row + updated label
private let kPadL:   CGFloat = 12   // left padding
private let kPadR:   CGFloat = 12   // right padding
private let kLedSz:  CGFloat = 6    // LED square size
private let kStatW:  CGFloat = 72   // status label column width
private let kNameX:  CGFloat = 24   // name column start (after LED)
private let kEmptyStateH: CGFloat = 126

class ServicesPanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    // MARK: - State (set by StatusBarController; no auto-reload — caller drives reloads)

    var services: [ServiceStatus] = []
    var lastUpdated: Date?
    var statusMessage: String?

    var onReorder:  (([ServiceStatus]) -> Void)?
    var onConnect:  (() -> Void)?
    var onRetry:    (() -> Void)?
    var onSettings: (() -> Void)?
    var onQuit:     (() -> Void)?

    private var panel:        NSPanel?
    private var tableView:    NSTableView?
    private var emptyStateView: NSView?
    private var emptyStateTitle: NSTextField?
    private var emptyStateDetail: NSTextField?
    private var emptyStateButton: NSButton?
    private var updatedLabel: NSTextField?
    private var eventMonitor: Any?

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: - Public

    func toggle(relativeTo button: NSStatusBarButton) {
        isVisible ? hide() : show(relativeTo: button)
    }

    func show(relativeTo button: NSStatusBarButton) {
        // Guard against leaking monitors on double-show
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }

        buildIfNeeded()
        reload()
        sizeAndPlace(relativeTo: button)
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
    }

    func hide() {
        panel?.orderOut(nil)
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
    }

    // MARK: - Sizing & placement

    private var hasSession: Bool {
        Config.hasOAuthSession()
    }

    private var hasProjectSelection: Bool {
        guard let projectID = Config.readProjectID() else { return false }
        return !projectID.isEmpty
    }

    private var showsConnectEmptyState: Bool {
        !hasSession && services.isEmpty
    }

    private var showsProjectSelectionEmptyState: Bool {
        hasSession && !hasProjectSelection && services.isEmpty
    }

    private var showsFetchErrorEmptyState: Bool {
        hasSession && hasProjectSelection && services.isEmpty && statusMessage != nil
    }

    private func bodyH() -> CGFloat {
        (showsConnectEmptyState || showsProjectSelectionEmptyState || showsFetchErrorEmptyState)
            ? kEmptyStateH
            : max(1, CGFloat(services.count)) * kRowH
    }

    private func totalH() -> CGFloat { bodyH() + kFooterH }

    private func sizeAndPlace(relativeTo button: NSStatusBarButton) {
        guard let bWin = button.window else { return }
        let total = totalH()
        panel?.setContentSize(NSSize(width: kW, height: total))
        let bodyFrame = NSRect(x: 0, y: kFooterH, width: kW, height: bodyH())
        tableView?.frame = bodyFrame
        emptyStateView?.frame = bodyFrame

        let btn    = bWin.convertToScreen(button.frame)
        let screen = bWin.screen ?? NSScreen.main
        let maxX   = screen?.frame.maxX ?? 2000
        let x = max(8, min(btn.maxX - kW, maxX - kW - 8))
        panel?.setFrameOrigin(NSPoint(x: x, y: btn.minY - total))
    }

    // MARK: - Build panel (once)

    private func buildIfNeeded() {
        guard panel == nil else { return }

        let p = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.backgroundColor = NSColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 0.97)
        p.isOpaque  = false
        p.hasShadow = true
        p.level     = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]

        let cv = p.contentView!

        let tv = NSTableView(frame: .zero)
        tv.backgroundColor  = .clear
        tv.rowHeight        = kRowH
        tv.intercellSpacing = .zero
        tv.headerView       = nil
        tv.dataSource       = self
        tv.delegate         = self
        tv.selectionHighlightStyle = .none
        tv.target = self
        tv.action = #selector(rowClicked)
        if #available(macOS 11.0, *) { tv.style = .fullWidth }

        let col = NSTableColumn(identifier: .init("svc"))
        col.width = kW; col.minWidth = kW; col.maxWidth = kW
        tv.addTableColumn(col)
        tv.registerForDraggedTypes([kDragType])
        tv.setDraggingSourceOperationMask(.move, forLocal: true)

        cv.addSubview(tv)
        self.tableView = tv

        let empty = buildEmptyStateView(frame: .zero)
        empty.isHidden = true
        cv.addSubview(empty)
        self.emptyStateView = empty

        let sep = NSBox()
        sep.boxType     = .separator
        sep.borderColor = NSColor(white: 0.15, alpha: 1)
        sep.frame = NSRect(x: 0, y: kFooterH - 1, width: kW, height: 1)
        cv.addSubview(sep)

        buildFooter(in: cv)
        self.panel = p
    }

    // MARK: - Footer

    private func buildFooter(in v: NSView) {
        let lbl = NSTextField(labelWithString: "")
        lbl.font      = .monospacedSystemFont(ofSize: 9, weight: .regular)
        lbl.textColor = NSColor(white: 0.28, alpha: 1)
        lbl.frame     = NSRect(x: kPadL, y: kFooterH - 18, width: kW - kPadL - kPadR, height: 13)
        v.addSubview(lbl)
        self.updatedLabel = lbl

        let half = kW / 2
        addLink("settings", x: kPadL, y: 10, w: half - kPadL - 4, in: v, sel: #selector(doSettings))
        addLink("quit",    x: half,  y: 10, w: half - kPadR,      in: v, sel: #selector(doQuit))
    }

    private func buildEmptyStateView(frame: NSRect) -> NSView {
        let view = NSView(frame: frame)

        let title = NSTextField(labelWithString: "")
        title.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        title.textColor = NSColor(white: 0.82, alpha: 1)
        title.alignment = .center
        title.frame = NSRect(x: 18, y: 80, width: kW - 36, height: 16)
        view.addSubview(title)
        self.emptyStateTitle = title

        let detail = NSTextField(labelWithString: "")
        detail.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        detail.textColor = NSColor(white: 0.42, alpha: 1)
        detail.alignment = .center
        detail.lineBreakMode = .byWordWrapping
        detail.maximumNumberOfLines = 2
        detail.frame = NSRect(x: 24, y: 48, width: kW - 48, height: 28)
        view.addSubview(detail)
        self.emptyStateDetail = detail

        let button = NSButton(frame: NSRect(x: 52, y: 14, width: kW - 104, height: 26))
        button.bezelStyle = .rounded
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor(red: 0.12, green: 0.42, blue: 0.98, alpha: 0.90).cgColor
        button.layer?.cornerRadius = 5
        button.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        button.contentTintColor = NSColor(white: 0.96, alpha: 1)
        button.target = self
        button.action = #selector(doEmptyStateAction)
        view.addSubview(button)
        self.emptyStateButton = button

        return view
    }

    private func addLink(_ title: String, x: CGFloat, y: CGFloat, w: CGFloat, in view: NSView, sel: Selector) {
        let lbl = ClickLabel(labelWithString: title)
        lbl.font      = .monospacedSystemFont(ofSize: 10, weight: .regular)
        lbl.textColor = NSColor(white: 0.42, alpha: 1)
        lbl.frame     = NSRect(x: x, y: y, width: w, height: 14)
        lbl.target    = self
        lbl.action    = sel
        view.addSubview(lbl)
    }

    private func updateLabel() {
        guard !showsConnectEmptyState else {
            updatedLabel?.textColor = NSColor(white: 0.28, alpha: 1)
            updatedLabel?.stringValue = "not connected"
            return
        }
        guard !showsProjectSelectionEmptyState else {
            updatedLabel?.textColor = NSColor(white: 0.28, alpha: 1)
            updatedLabel?.stringValue = "project not selected"
            return
        }
        if let statusMessage {
            updatedLabel?.textColor = NSColor(red: 0.88, green: 0.60, blue: 0.14, alpha: 1)
            if let date = lastUpdated {
                let f = DateFormatter()
                f.timeStyle = .medium
                updatedLabel?.stringValue = "stale \(f.string(from: date)) — \(compact(statusMessage))"
            } else {
                updatedLabel?.stringValue = compact(statusMessage)
            }
            return
        }
        updatedLabel?.textColor = NSColor(white: 0.28, alpha: 1)
        guard let date = lastUpdated else { updatedLabel?.stringValue = ""; return }
        let f = DateFormatter(); f.timeStyle = .medium
        updatedLabel?.stringValue = "updated \(f.string(from: date))"
    }

    private func updateEmptyState() {
        if showsFetchErrorEmptyState {
            emptyStateTitle?.stringValue = "Railway status unavailable"
            emptyStateDetail?.stringValue = statusMessage ?? "The latest status request failed."
            emptyStateButton?.title = "Retry Now"
        } else if showsProjectSelectionEmptyState {
            emptyStateTitle?.stringValue = "No Railway project selected"
            emptyStateDetail?.stringValue = "Open settings to choose a project for live service status."
            emptyStateButton?.title = "Open Settings"
        } else {
            emptyStateTitle?.stringValue = "No Railway account connected"
            emptyStateDetail?.stringValue = "Authenticate to load projects and live service status."
            emptyStateButton?.title = "Connect Railway Account"
        }
    }

    // MARK: - Table data source

    func numberOfRows(in tableView: NSTableView) -> Int { services.count }

    func reload() {
        updateLabel()
        updateEmptyState()
        let showEmpty = showsConnectEmptyState || showsProjectSelectionEmptyState || showsFetchErrorEmptyState
        emptyStateView?.isHidden = !showEmpty
        tableView?.isHidden = showEmpty
        tableView?.reloadData()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let svc   = services[row]
        let color = LEDColor(status: svc.status)
        let colW  = tableColumn?.width ?? kW

        let cell = TappableCell(frame: NSRect(x: 0, y: 0, width: colW, height: kRowH))

        let led = FlatSquare(frame: NSRect(x: kPadL, y: (kRowH - kLedSz) / 2, width: kLedSz, height: kLedSz))
        led.color = color.nsColor
        cell.addSubview(led)

        let statX  = colW - kPadR - kStatW
        let status = NSTextField(labelWithString: color.label)
        status.font      = .monospacedSystemFont(ofSize: 9, weight: .regular)
        status.textColor = color == .gray ? NSColor(white: 0.28, alpha: 1) : color.nsColor.withAlphaComponent(0.60)
        status.alignment = .right
        status.frame     = NSRect(x: statX, y: (kRowH - 13) / 2, width: kStatW, height: 13)
        cell.addSubview(status)

        let name = NSTextField(labelWithString: svc.name)
        name.font          = .monospacedSystemFont(ofSize: 11, weight: .regular)
        name.textColor     = NSColor(white: 0.76, alpha: 1)
        name.lineBreakMode = .byTruncatingTail
        name.frame         = NSRect(x: kNameX, y: (kRowH - 15) / 2, width: statX - kNameX - 6, height: 15)
        cell.addSubview(name)

        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { FlatRowView() }

    // MARK: - Drag & Drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: kDragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let str  = info.draggingPasteboard.string(forType: kDragType),
              let from = Int(str), from != row else { return false }

        var list = services
        let item = list.remove(at: from)
        let dest = max(0, min(from < row ? row - 1 : row, list.count))
        list.insert(item, at: dest)

        tableView.beginUpdates()
        tableView.moveRow(at: from, to: dest)
        tableView.endUpdates()

        services = list
        onReorder?(list)
        return true
    }

    // MARK: - Actions

    @objc private func rowClicked() {
        guard let tv = tableView else { return }
        let row = tv.clickedRow
        guard row >= 0, row < services.count else { return }
        let svc = services[row]
        let pid = Config.readProjectID() ?? ""
        guard let url = URL(string: "https://railway.app/project/\(pid)/service/\(svc.id)") else { return }
        hide()
        NSWorkspace.shared.open(url)
    }

    @objc private func doEmptyStateAction() {
        hide()
        if showsConnectEmptyState {
            onConnect?()
        } else if showsFetchErrorEmptyState {
            onRetry?()
        } else {
            onSettings?()
        }
    }

    @objc private func doSettings() { hide(); onSettings?() }
    @objc private func doQuit()     { onQuit?() }

    private func compact(_ message: String) -> String {
        let collapsed = message.replacingOccurrences(of: "\n", with: " ")
        guard collapsed.count > 58 else { return collapsed }
        return String(collapsed.prefix(55)) + "..."
    }
}

// MARK: - Helper views

class FlatSquare: NSView {
    var color: NSColor = .clear { didSet { needsDisplay = true } }
    override func draw(_ dirty: NSRect) { color.setFill(); bounds.fill() }
}

class FlatRowView: NSTableRowView {
    override func drawBackground(in dirty: NSRect) {
        NSColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1).setFill()
        dirty.fill()
    }
    override func drawSelection(in dirty: NSRect) {}
}

class TappableCell: NSView {
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

class ClickLabel: NSTextField {
    override func mouseUp(with event: NSEvent) {
        if let t = target, let a = action { NSApp.sendAction(a, to: t, from: self) }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
