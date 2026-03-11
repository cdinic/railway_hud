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
    case unauthorized
    case network(String)
    case parse(String)

    var errorDescription: String? {
        switch self {
        case .noToken:        return "Not connected — open Settings and sign in with Railway"
        case .unauthorized:   return "Session expired — reconnect to Railway"
        case .network(let m): return "Network: \(m)"
        case .parse(let m):   return "Parse error: \(m)"
        }
    }

    var isSignInRequired: Bool {
        switch self {
        case .noToken, .unauthorized:
            return true
        case .network, .parse:
            return false
        }
    }
}

class RailwayAPI {
    private let apiURL = URL(string: "https://backboard.railway.com/graphql/v2")!
    private var hasSession: Bool {
        Config.readOAuthToken() != nil || Config.readRefreshToken() != nil
    }

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
        guard hasSession, let pid = Config.readProjectID(), !pid.isEmpty else {
            completion(.failure(APIError.noToken)); return
        }
        performAuthorizedRequest(query: statusQuery(projectID: pid)) { [weak self] data, _, error in
            self?.parseStatusResponse(data: data, error: error, completion: completion)
        }
    }

    private func parseStatusResponse(data: Data?, error: Error?,
                                     completion: (Result<[ServiceStatus], Error>) -> Void) {
        if let apiError = error as? APIError {
            completion(.failure(apiError))
            return
        }
        if let error { completion(.failure(APIError.network(error.localizedDescription))); return }
        guard let data else { completion(.failure(APIError.parse("Empty response"))); return }

        if let message = graphQLErrorMessage(in: data) {
            if message == "Not Authorized" {
                Config.clearOAuthTokens()
                completion(.failure(APIError.unauthorized))
            } else {
                completion(.failure(APIError.network(message)))
            }
            return
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
        guard hasSession else {
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
        performAuthorizedRequest(query: query) { [weak self] data, _, error in
            self?.parseProjectsResponse(data: data, error: error, completion: completion)
        }
    }

    private func parseProjectsResponse(data: Data?, error: Error?,
                                       completion: (Result<[ProjectInfo], Error>) -> Void) {
        if let apiError = error as? APIError {
            completion(.failure(apiError))
            return
        }
        if let error { completion(.failure(APIError.network(error.localizedDescription))); return }
        guard let data else { completion(.failure(APIError.parse("Empty response"))); return }

        if let message = graphQLErrorMessage(in: data) {
            if message == "Not Authorized" {
                Config.clearOAuthTokens()
                completion(.failure(APIError.unauthorized))
            } else {
                completion(.failure(APIError.network(message)))
            }
            return
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

    // MARK: - Shared request helper

    private func performAuthorizedRequest(query: String,
                                          retryingAuth: Bool = false,
                                          completion: @escaping (Data?, Int, Error?) -> Void) {
        OAuthManager.shared.withValidAccessToken(forceRefresh: retryingAuth) { [weak self] token in
            guard let self else { return }
            guard let token else {
                completion(nil, 0, APIError.unauthorized)
                return
            }

            self.performRequest(query: query, token: token) { data, statusCode, error in
                if self.isUnauthorizedResponse(data: data, statusCode: statusCode), !retryingAuth {
                    OAuthManager.shared.refreshToken(force: true) { refreshed in
                        guard refreshed else {
                            Config.clearOAuthTokens()
                            completion(nil, statusCode, APIError.unauthorized)
                            return
                        }
                        self.performAuthorizedRequest(query: query, retryingAuth: true, completion: completion)
                    }
                    return
                }
                completion(data, statusCode, error)
            }
        }
    }

    private func performRequest(query: String, token: String,
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

    private func graphQLErrorMessage(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = json["errors"] as? [[String: Any]],
              let message = errors.first?["message"] as? String else { return nil }
        return message
    }

    private func isUnauthorizedResponse(data: Data?, statusCode: Int) -> Bool {
        if statusCode == 401 || statusCode == 403 {
            return true
        }
        guard let data, let message = graphQLErrorMessage(in: data) else { return false }
        return message == "Not Authorized"
    }
}
