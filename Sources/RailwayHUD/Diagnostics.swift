import Foundation
import OSLog

struct DiagnosticEvent: Codable {
    let timestamp: Date
    let category: String
    let message: String
    let metadata: [String: String]
}

final class Diagnostics {
    static let shared = Diagnostics()

    private let storeKey = "com.railway-hud.diagnostics.events"
    private let maxEvents = 250
    private let queue = DispatchQueue(label: "com.railway-hud.diagnostics")
    private let logger = Logger(subsystem: "com.local.railway-hud", category: "diagnostics")

    private var events: [DiagnosticEvent]

    private init() {
        if let data = UserDefaults.standard.data(forKey: storeKey),
           let decoded = try? JSONDecoder().decode([DiagnosticEvent].self, from: data) {
            events = decoded
        } else {
            events = []
        }
    }

    func log(_ category: String, _ message: String, metadata: [String: String] = [:]) {
        let event = DiagnosticEvent(timestamp: Date(), category: category, message: message, metadata: metadata)
        let line = format(event)
        logger.notice("\(line, privacy: .public)")

        queue.async {
            self.events.append(event)
            if self.events.count > self.maxEvents {
                self.events.removeFirst(self.events.count - self.maxEvents)
            }
            self.persist()
        }
    }

    func exportText() -> String {
        queue.sync {
            guard !events.isEmpty else { return "No diagnostics captured yet." }
            return events.map(format).joined(separator: "\n")
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }

    private func format(_ event: DiagnosticEvent) -> String {
        let stamp = Self.timestampFormatter.string(from: event.timestamp)
        let metadata = event.metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        return metadata.isEmpty
            ? "\(stamp) [\(event.category)] \(event.message)"
            : "\(stamp) [\(event.category)] \(event.message) \(metadata)"
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
