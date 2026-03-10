import Foundation

/// Single source of truth for all shared constants and cross-cutting helpers.
enum Config {
    static let projectID = "8ac14052-180d-4919-9623-d3ec163e20ec"
    static let tokenFile = NSHomeDirectory() + "/.railway-hud"
    static let orderKey  = "com.railway-hud.serviceOrder"

    /// Reads the API token from the environment variable or the config file.
    static func readToken() -> String? {
        if let t = ProcessInfo.processInfo.environment["RAILWAY_TOKEN"], !t.isEmpty { return t }
        guard let content = try? String(contentsOfFile: tokenFile, encoding: .utf8) else { return nil }
        for line in content.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("RAILWAY_TOKEN=") else { continue }
            let v = String(t.dropFirst("RAILWAY_TOKEN=".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
            if !v.isEmpty { return v }
        }
        return nil
    }
}
