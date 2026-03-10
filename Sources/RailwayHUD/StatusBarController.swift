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

    private var isDisconnectedOrUnauthed: Bool {
        Config.readOAuthToken() == nil || (Config.readProjectID()?.isEmpty != false)
    }

    init() {
        guard let button = statusItem.button else { return }
        button.image = LEDView.render(colors: currentColors())
        button.action = #selector(togglePanel)
        button.target = self
        button.sendAction(on: [.leftMouseUp])

        panel.onConnect  = { [weak self] in self?.startOAuthFlow() }
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
                case .failure(let error):
                    self?.services = []
                    if let apiError = error as? APIError, case .noToken = apiError {
                        self?.hasError = false
                    } else {
                        self?.hasError = true
                    }
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
        statusItem.button?.image = LEDView.render(colors: currentColors())

        panel.services = services
        if panel.isVisible { panel.reload() }
    }

    private func currentColors() -> [LEDColor] {
        if hasError || isDisconnectedOrUnauthed {
            return [.red]
        }
        return services.isEmpty ? [.gray] : services.map { LEDColor(status: $0.status) }
    }

    // MARK: - Actions

    @objc private func togglePanel() {
        guard let button = statusItem.button else { return }
        panel.toggle(relativeTo: button)
    }

    private func startOAuthFlow() {
        OAuthManager.shared.onSuccess = { [weak self] in
            DispatchQueue.main.async {
                self?.finishOAuthConnection()
            }
        }
        OAuthManager.shared.startFlow()
    }

    private func finishOAuthConnection() {
        api.fetchProjects { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }

                switch result {
                case .success(let projects):
                    if let selectedProjectID = Config.readProjectID(),
                       projects.contains(where: { $0.id == selectedProjectID }) {
                        self.fetch()
                        return
                    }

                    if projects.count == 1, let project = projects.first {
                        Config.saveProjectID(project.id)
                        self.fetch()
                        return
                    }

                    self.fetch()
                    self.openSettings()

                case .failure:
                    self.fetch()
                    self.openSettings()
                }
            }
        }
    }

    private func openSettings() {
        if settings == nil {
            settings = SettingsWindowController()
            settings?.onConfigurationChange = { [weak self] in self?.fetch() }
            settings?.onConnectRequested = { [weak self] in self?.startOAuthFlow() }
        }
        settings?.show()
    }
}
