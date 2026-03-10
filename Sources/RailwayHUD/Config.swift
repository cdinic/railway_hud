import Foundation

/// Single source of truth for all shared constants and cross-cutting helpers.
enum Config {
    static let tokenFile = NSHomeDirectory() + "/.railway-hud"
    static let orderKey  = "com.railway-hud.serviceOrder"

    /// Reads a value for the given key from the config file (format: KEY=value).
    private static func readValue(forKey key: String) -> String? {
        if key == "RAILWAY_TOKEN",
           let t = ProcessInfo.processInfo.environment["RAILWAY_TOKEN"], !t.isEmpty { return t }
        guard let content = try? String(contentsOfFile: tokenFile, encoding: .utf8) else { return nil }
        for line in content.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("\(key)=") else { continue }
            let v = String(t.dropFirst("\(key)=".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
            if !v.isEmpty { return v }
        }
        return nil
    }

    static func readToken()     -> String? { readValue(forKey: "RAILWAY_TOKEN") }
    static func readProjectID() -> String? { readValue(forKey: "RAILWAY_PROJECT_ID") }

    /// Persist both token and project ID to the config file.
    static func save(token: String, projectID: String) throws {
        let contents = "RAILWAY_TOKEN=\(token)\nRAILWAY_PROJECT_ID=\(projectID)\n"
        try contents.write(toFile: tokenFile, atomically: true, encoding: .utf8)
    }
}
