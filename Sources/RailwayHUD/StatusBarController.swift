import AppKit

private let pollInterval: TimeInterval = 30

class StatusBarController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let api        = RailwayAPI()
    private let panel      = ServicesPanelController()
    private var settings:  SettingsWindowController?

    private var services: [ServiceStatus] = []
    private var lastUpdated: Date?
    private var lastErrorMessage: String?
    private var lastHUDSignature: String?
    private var pollTimer: Timer?

    private var savedOrder: [String] {
        get { UserDefaults.standard.stringArray(forKey: Config.orderKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Config.orderKey) }
    }

    private var isDisconnectedOrUnauthed: Bool {
        !Config.hasOAuthSession() || (Config.readProjectID()?.isEmpty != false)
    }

    init() {
        guard let button = statusItem.button else { return }
        button.image = LEDView.render(colors: currentColors())
        button.action = #selector(togglePanel)
        button.target = self
        button.sendAction(on: [.leftMouseUp])

        panel.onConnect  = { [weak self] in self?.startOAuthFlow() }
        panel.onRetry    = { [weak self] in self?.fetch(trigger: "retry") }
        panel.onSettings = { [weak self] in self?.openSettings() }
        panel.onQuit     = { NSApplication.shared.terminate(nil) }
        panel.onReorder  = { [weak self] reordered in
            self?.services   = reordered
            self?.savedOrder = reordered.map { $0.id }
        }

        fetch(trigger: "launch")
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.fetch(trigger: "poll")
        }
    }

    // MARK: - Fetch

    func handleLifecycleEvent(_ event: String) {
        fetch(trigger: event)
    }

    private func fetch(trigger: String) {
        Diagnostics.shared.log("status", "fetch started", metadata: fetchContext(trigger: trigger))
        api.fetchStatus { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let svcs):
                    self.services = self.applyOrder(to: svcs)
                    self.lastUpdated = Date()
                    self.lastErrorMessage = nil
                    Diagnostics.shared.log("status", "fetch succeeded",
                                           metadata: self.fetchSuccessContext(trigger: trigger, services: svcs))
                case .failure(let error):
                    if let apiError = error as? APIError, apiError.isSignInRequired {
                        self.services = []
                        self.lastErrorMessage = nil
                    } else {
                        self.lastErrorMessage = error.localizedDescription
                    }
                    Diagnostics.shared.log("status", "fetch failed",
                                           metadata: self.fetchFailureContext(trigger: trigger, error: error))
                }
                self.refresh()
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
        let colors = currentColors()
        statusItem.button?.image = LEDView.render(colors: colors)
        logHUDTransition(colors: colors)

        panel.services = services
        panel.lastUpdated = lastUpdated
        panel.statusMessage = lastErrorMessage
        if panel.isVisible { panel.reload() }
    }

    private func currentColors() -> [LEDColor] {
        if isDisconnectedOrUnauthed {
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
        Diagnostics.shared.log("oauth", "connect requested")
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
                    Diagnostics.shared.log("oauth", "project fetch succeeded", metadata: ["projects": "\(projects.count)"])
                    if let selectedProjectID = Config.readProjectID(),
                       projects.contains(where: { $0.id == selectedProjectID }) {
                        self.fetch(trigger: "oauth_success")
                        return
                    }

                    if projects.count == 1, let project = projects.first {
                        Config.saveProjectID(project.id)
                        Diagnostics.shared.log("oauth", "auto-selected project",
                                               metadata: ["projectID": project.id, "name": project.name])
                        self.fetch(trigger: "oauth_auto_project")
                        return
                    }

                    self.fetch(trigger: "oauth_needs_project")
                    self.openSettings()

                case .failure(let error):
                    Diagnostics.shared.log("oauth", "project fetch failed", metadata: ["error": error.localizedDescription])
                    self.fetch(trigger: "oauth_project_failure")
                    self.openSettings()
                }
            }
        }
    }

    private func openSettings() {
        if settings == nil {
            settings = SettingsWindowController()
            settings?.onConfigurationChange = { [weak self] in self?.fetch(trigger: "settings_change") }
            settings?.onConnectRequested = { [weak self] in self?.startOAuthFlow() }
        }
        settings?.show()
    }

    private func fetchContext(trigger: String) -> [String: String] {
        var context: [String: String] = [
            "trigger": trigger,
            "session": Config.hasOAuthSession() ? "present" : "missing",
            "project": Config.readProjectID()?.isEmpty == false ? "selected" : "missing",
            "servicesCached": "\(services.count)"
        ]
        if let expiry = Config.readAccessTokenExpiry() {
            context["tokenExpiry"] = ISO8601DateFormatter().string(from: expiry)
        }
        return context
    }

    private func fetchSuccessContext(trigger: String, services: [ServiceStatus]) -> [String: String] {
        var context = fetchContext(trigger: trigger)
        context["services"] = "\(services.count)"
        let grouped = Dictionary(grouping: services, by: { $0.status.uppercased() })
        context["statuses"] = grouped
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value.count)" }
            .joined(separator: ",")
        return context
    }

    private func fetchFailureContext(trigger: String, error: Error) -> [String: String] {
        var context = fetchContext(trigger: trigger)
        context["error"] = error.localizedDescription
        if let apiError = error as? APIError {
            context["authRequired"] = apiError.isSignInRequired ? "true" : "false"
        }
        return context
    }

    private func logHUDTransition(colors: [LEDColor]) {
        let signature = colors.map(ledName).joined(separator: ",")
        guard signature != lastHUDSignature else { return }
        lastHUDSignature = signature
        Diagnostics.shared.log("hud", "state changed", metadata: [
            "colors": signature,
            "services": "\(services.count)",
            "error": lastErrorMessage ?? "none"
        ])
    }

    private func ledName(_ color: LEDColor) -> String {
        switch color {
        case .green: return "green"
        case .yellow: return "yellow"
        case .blue: return "blue"
        case .red: return "red"
        case .gray: return "gray"
        }
    }
}
