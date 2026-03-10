import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = StatusBarController()

        // Apple Events handler — traditional macOS URL scheme delivery mechanism.
        // kInternetEventClass ('GURL') = 0x4755524C, kAEGetURL ('GURL') = 0x4755524C
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(0x4755524C),
            andEventID:   AEEventID(0x4755524C)
        )
    }

    // Modern delegate method — also fires for custom URL schemes on macOS 10.13+.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            OAuthManager.shared.handleCallback(url: url)
        }
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor,
                                      withReplyEvent: NSAppleEventDescriptor) {
        // keyDirectObject ('----') = 0x2D2D2D2D
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(0x2D2D2D2D))?.stringValue,
              let url = URL(string: urlString)
        else { return }
        OAuthManager.shared.handleCallback(url: url)
    }
}
