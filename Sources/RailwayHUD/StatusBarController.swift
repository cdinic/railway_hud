import AppKit

private let pollInterval: TimeInterval = 30

class StatusBarController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let api        = RailwayAPI()
    private let panel      = ServicesPanelController()
    private var settings:  SettingsWindowController?

    private var services: [ServiceStatus] = []
    private var hasError  = false
    private var pollTimer: Timer?

    private var savedOrder: [String] {
        get { UserDefaults.standard.stringArray(forKey: Config.orderKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Config.orderKey) }
    }

    init() {
        guard let button = statusItem.button else { return }
        button.image = LEDView.render(colors: [.gray])
        button.action = #selector(togglePanel)
        button.target = self
        button.sendAction(on: [.leftMouseUp])

        panel.onSettings = { [weak self] in self?.openSettings() }
        panel.onQuit     = { NSApplication.shared.terminate(nil) }
        panel.onReorder  = { [weak self] reordered in
            self?.services   = reordered
            self?.savedOrder = reordered.map { $0.id }
        }

        fetch()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.fetch()
        }
    }

    // MARK: - Fetch

    private func fetch() {
        api.fetchStatus { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let svcs):
                    self?.services = self?.applyOrder(to: svcs) ?? svcs
                    self?.hasError = false
                case .failure:
                    self?.hasError = true
                }
                self?.refresh()
            }
        }
    }

    private func applyOrder(to svcs: [ServiceStatus]) -> [ServiceStatus] {
        let order = savedOrder
        guard !order.isEmpty else { return svcs }
        var dict   = Dictionary(uniqueKeysWithValues: svcs.map { ($0.id, $0) })
        var result = order.compactMap { dict.removeValue(forKey: $0) }
        result    += dict.values
        return result
    }

    // MARK: - Refresh

    private func refresh() {
        let colors: [LEDColor] = hasError
            ? [.red]
            : services.isEmpty ? [.gray] : services.map { LEDColor(status: $0.status) }
        statusItem.button?.image = LEDView.render(colors: colors)

        panel.services = services
        panel.hasError = hasError
        if panel.isVisible { panel.reload() }
    }

    // MARK: - Actions

    @objc private func togglePanel() {
        guard let button = statusItem.button else { return }
        panel.toggle(relativeTo: button)
    }

    private func openSettings() {
        if settings == nil {
            settings = SettingsWindowController()
            settings?.onSave = { [weak self] in self?.fetch() }
        }
        settings?.show()
    }
}
