import Foundation

struct ServiceStatus {
    let id: String
    let name: String
    let status: String
}

struct ProjectInfo {
    let id: String
    let name: String
}

enum APIError: LocalizedError {
    case noToken
    case network(String)
    case parse(String)

    var errorDescription: String? {
        switch self {
        case .noToken:        return "Not connected — open Settings and sign in with Railway"
        case .network(let m): return "Network: \(m)"
        case .parse(let m):   return "Parse error: \(m)"
        }
    }
}

class RailwayAPI {
    private let apiURL = URL(string: "https://backboard.railway.com/graphql/v2")!

    // MARK: - Fetch service statuses

    private func statusQuery(projectID: String) -> String {
        """
        {
          project(id: "\(projectID)") {
            services {
              edges {
                node {
                  id
                  name
                  deployments(first: 1) {
                    edges { node { status } }
                  }
                }
              }
            }
          }
        }
        """
    }

    func fetchStatus(completion: @escaping (Result<[ServiceStatus], Error>) -> Void) {
        guard let token = Config.readOAuthToken(), let pid = Config.readProjectID(), !pid.isEmpty else {
            completion(.failure(APIError.noToken)); return
        }
        performRequest(query: statusQuery(projectID: pid), token: token, retrying: false) { [weak self] data, statusCode, error in
            if statusCode == 401 {
                // Access token expired — try refreshing once
                OAuthManager.shared.refreshToken { refreshed in
                    guard refreshed, let newToken = Config.readOAuthToken() else {
                        completion(.failure(APIError.network("Session expired — please reconnect"))); return
                    }
                    self?.performRequest(query: self!.statusQuery(projectID: pid), token: newToken, retrying: true) { data, _, error in
                        self?.parseStatusResponse(data: data, error: error, completion: completion)
                    }
                }
                return
            }
            self?.parseStatusResponse(data: data, error: error, completion: completion)
        }
    }

    private func parseStatusResponse(data: Data?, error: Error?,
                                     completion: (Result<[ServiceStatus], Error>) -> Void) {
        if let error { completion(.failure(APIError.network(error.localizedDescription))); return }
        guard let data else { completion(.failure(APIError.parse("Empty response"))); return }

        if let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errors  = json["errors"] as? [[String: Any]],
           let msg     = errors.first?["message"] as? String {
            completion(.failure(APIError.network(msg))); return
        }

        guard
            let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let dataObj = json["data"] as? [String: Any],
            let project = dataObj["project"] as? [String: Any],
            let edges   = (project["services"] as? [String: Any])?["edges"] as? [[String: Any]]
        else {
            completion(.failure(APIError.parse("Unexpected response shape"))); return
        }

        let result: [ServiceStatus] = edges.compactMap { edge in
            guard
                let node = edge["node"] as? [String: Any],
                let id   = node["id"]   as? String,
                let name = node["name"] as? String
            else { return nil }

            let status = (node["deployments"] as? [String: Any])
                .flatMap { ($0["edges"] as? [[String: Any]])?.first }
                .flatMap { ($0["node"] as? [String: Any])?["status"] as? String }
                ?? "UNKNOWN"

            return ServiceStatus(id: id, name: name, status: status)
        }
        completion(.success(result))
    }

    // MARK: - Fetch projects (for project picker in Settings)

    func fetchProjects(completion: @escaping (Result<[ProjectInfo], Error>) -> Void) {
        guard let token = Config.readOAuthToken() else {
            completion(.failure(APIError.noToken)); return
        }
        let query = """
        {
          externalWorkspaces {
            id
            name
            projects {
              id
              name
            }
          }
        }
        """
        performRequest(query: query, token: token, retrying: false) { data, _, error in
            if let error { completion(.failure(APIError.network(error.localizedDescription))); return }
            guard let data else { completion(.failure(APIError.parse("Empty response"))); return }

            // Surface any GraphQL errors first.
            if let json   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errors = json["errors"] as? [[String: Any]],
               let msg    = errors.first?["message"] as? String {
                completion(.failure(APIError.network(msg))); return
            }

            guard
                let json       = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let dataObj    = json["data"] as? [String: Any],
                let workspaces = dataObj["externalWorkspaces"] as? [[String: Any]]
            else {
                let raw = String(data: data, encoding: .utf8) ?? "(unreadable)"
                completion(.failure(APIError.parse(raw))); return
            }

            var seenIDs = Set<String>()
            let result: [ProjectInfo] = workspaces
                .flatMap { $0["projects"] as? [[String: Any]] ?? [] }
                .compactMap { project in
                    guard let id = project["id"] as? String,
                          let name = project["name"] as? String,
                          seenIDs.insert(id).inserted else { return nil }
                    return ProjectInfo(id: id, name: name)
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            if result.isEmpty {
                completion(.failure(APIError.network("No authorized projects. Reconnect and approve at least one project.")))
                return
            }
            completion(.success(result))
        }
    }

    // MARK: - Shared request helper

    private func performRequest(query: String, token: String, retrying: Bool,
                                completion: @escaping (Data?, Int, Error?) -> Void) {
        var request = URLRequest(url: apiURL, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json",  forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)",   forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query])

        URLSession.shared.dataTask(with: request) { data, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            completion(data, code, error)
        }.resume()
    }
}
