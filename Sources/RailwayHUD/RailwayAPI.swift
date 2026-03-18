import Foundation

struct ServiceStatus {
    let id: String
    let name: String
    let status: String
    let deployedAt: Date?
    let serviceID: String?
    let environmentID: String?
    let environmentName: String?
}

struct ProjectInfo {
    let id: String
    let name: String
}

struct ProjectServiceInfo {
    let id: String
    let name: String
}

struct EnvironmentInfo {
    let id: String
    let name: String
}

struct EnvironmentStatusFetchResult {
    let environment: EnvironmentInfo
    let services: [ServiceStatus]
    let error: Error?
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
    private static let fractionalSecondsDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let standardDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    private var hasSession: Bool {
        Config.hasOAuthSession()
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
                    edges { node { status createdAt updatedAt } }
                  }
                }
              }
            }
          }
        }
        """
    }

    private func projectTopologyQuery(projectID: String) -> String {
        """
        {
          project(id: "\(projectID)") {
            services {
              edges {
                node {
                  id
                  name
                }
              }
            }
            environments {
              edges {
                node {
                  id
                  name
                }
              }
            }
          }
        }
        """
    }

    private func environmentStatusQuery(environmentID: String) -> String {
        """
        {
          environment(id: "\(environmentID)") {
            id
            name
            serviceInstances {
              edges {
                node {
                  id
                  serviceName
                  latestDeployment {
                    status
                    createdAt
                    updatedAt
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
        fetchEnvironmentAwareStatus(projectID: pid, completion: completion)
    }

    private func fetchEnvironmentAwareStatus(projectID: String,
                                             completion: @escaping (Result<[ServiceStatus], Error>) -> Void) {
        performAuthorizedRequest(query: projectTopologyQuery(projectID: projectID)) { [weak self] data, _, error in
            guard let self else { return }

            switch self.parseProjectTopologyResponse(data: data, error: error) {
            case .success(let topology):
                guard !topology.environments.isEmpty else {
                    self.fetchFlatProjectStatus(projectID: projectID, completion: completion)
                    return
                }
                self.fetchStatusesForEnvironments(topology.environments,
                                                  services: topology.services,
                                                  servicesByName: topology.servicesByName) { result in
                    switch result {
                    case .success(let services):
                        completion(.success(services))
                    case .failure:
                        self.fetchFlatProjectStatus(projectID: projectID, completion: completion)
                    }
                }

            case .failure:
                self.fetchFlatProjectStatus(projectID: projectID, completion: completion)
            }
        }
    }

    private func fetchFlatProjectStatus(projectID: String,
                                        completion: @escaping (Result<[ServiceStatus], Error>) -> Void) {
        performAuthorizedRequest(query: statusQuery(projectID: projectID)) { [weak self] data, _, error in
            guard let self else { return }
            completion(self.parseFlatStatusResult(data: data, error: error))
        }
    }

    func parseFlatStatusResult(data: Data?, error: Error?) -> Result<[ServiceStatus], Error> {
        if let apiError = error as? APIError {
            return .failure(apiError)
        }
        if let error { return .failure(APIError.network(error.localizedDescription)) }
        guard let data else { return .failure(APIError.parse("Empty response")) }

        if let message = graphQLErrorMessage(in: data) {
            if message == "Not Authorized" {
                Config.clearOAuthTokens()
                return .failure(APIError.unauthorized)
            } else {
                return .failure(APIError.network(message))
            }
        }

        guard
            let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let dataObj = json["data"] as? [String: Any],
            let project = dataObj["project"] as? [String: Any],
            let edges   = (project["services"] as? [String: Any])?["edges"] as? [[String: Any]]
        else {
            return .failure(APIError.parse("Unexpected response shape"))
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

            let deploymentNode = (node["deployments"] as? [String: Any])
                .flatMap { ($0["edges"] as? [[String: Any]])?.first }
                .flatMap { $0["node"] as? [String: Any] }
            let deployedAt = (deploymentNode?["createdAt"] as? String)
                .flatMap(parseGraphQLDate(_:))
                ?? (deploymentNode?["updatedAt"] as? String).flatMap(parseGraphQLDate(_:))

            return ServiceStatus(id: id,
                                 name: name,
                                 status: status,
                                 deployedAt: deployedAt,
                                 serviceID: id,
                                 environmentID: nil,
                                 environmentName: nil)
        }
        return .success(result)
    }

    func parseProjectTopologyResponse(data: Data?, error: Error?)
        -> Result<(services: [ProjectServiceInfo], environments: [EnvironmentInfo], servicesByName: [String: String]), Error> {
        if let apiError = error as? APIError {
            return .failure(apiError)
        }
        if let error {
            return .failure(APIError.network(error.localizedDescription))
        }
        guard let data else {
            return .failure(APIError.parse("Empty response"))
        }

        if let message = graphQLErrorMessage(in: data) {
            if message == "Not Authorized" {
                Config.clearOAuthTokens()
                return .failure(APIError.unauthorized)
            }
            return .failure(APIError.network(message))
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let dataObj = json["data"] as? [String: Any],
            let project = dataObj["project"] as? [String: Any]
        else {
            return .failure(APIError.parse("Unexpected response shape"))
        }

        let serviceNodes = edgeNodes(from: project["services"])
        let environmentNodes = edgeNodes(from: project["environments"])
        let services = serviceNodes.compactMap { service -> ProjectServiceInfo? in
            guard let id = service["id"] as? String,
                  let name = service["name"] as? String else { return nil }
            return ProjectServiceInfo(id: id, name: name)
        }

        var servicesByName: [String: String] = [:]
        for service in services {
            guard
                servicesByName[service.name] == nil else { continue }
            servicesByName[service.name] = service.id
        }

        let environments = environmentNodes.compactMap { environment -> EnvironmentInfo? in
            guard let id = environment["id"] as? String,
                  let name = environment["name"] as? String else { return nil }
            return EnvironmentInfo(id: id, name: name)
        }

        return .success((services, environments, servicesByName))
    }

    private func fetchStatusesForEnvironments(_ environments: [EnvironmentInfo],
                                              services: [ProjectServiceInfo],
                                              servicesByName: [String: String],
                                              completion: @escaping (Result<[ServiceStatus], Error>) -> Void) {
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "com.local.railway-hud.environment-status")
        var results: [EnvironmentStatusFetchResult] = []

        for environment in environments {
            group.enter()
            performAuthorizedRequest(query: environmentStatusQuery(environmentID: environment.id)) { [weak self] data, _, error in
                defer { group.leave() }
                guard let self else { return }

                let parsed = self.parseEnvironmentStatusResponse(data: data,
                                                                error: error,
                                                                environment: environment,
                                                                servicesByName: servicesByName)

                queue.sync {
                    switch parsed {
                    case .success(let services):
                        results.append(EnvironmentStatusFetchResult(environment: environment,
                                                                    services: services,
                                                                    error: nil))
                    case .failure(let error):
                        results.append(EnvironmentStatusFetchResult(environment: environment,
                                                                    services: [],
                                                                    error: error))
                    }
                }
            }
        }

        group.notify(queue: .global()) {
            let merged = self.mergeEnvironmentStatuses(results,
                                                       services: services)
            if case .success(let serviceStatuses) = merged,
               results.contains(where: { $0.error != nil }) {
                let failedEnvironments = results
                    .filter { $0.error != nil }
                    .map { $0.environment.name }
                    .joined(separator: ",")
                Diagnostics.shared.log("status",
                                       "environment fetch degraded",
                                       metadata: [
                                        "failedEnvironments": failedEnvironments,
                                        "renderedServices": "\(serviceStatuses.count)"
                                       ])
            }
            completion(merged)
        }
    }

    func mergeEnvironmentStatuses(_ results: [EnvironmentStatusFetchResult],
                                  services: [ProjectServiceInfo]) -> Result<[ServiceStatus], Error> {
        var collected: [ServiceStatus] = []
        var firstError: Error?
        var successfulEnvironmentIDs = Set<String>()

        for result in results {
            if let error = result.error {
                if firstError == nil {
                    firstError = error
                }
                continue
            }
            successfulEnvironmentIDs.insert(result.environment.id)
            collected += result.services
        }

        guard !successfulEnvironmentIDs.isEmpty else {
            return .failure(firstError ?? APIError.parse("No environment responses"))
        }

        for result in results where result.error != nil {
            collected += placeholderServices(for: result.environment, services: services)
        }

        let sorted = collected.sorted {
            let lhsEnv = $0.environmentName ?? ""
            let rhsEnv = $1.environmentName ?? ""
            if lhsEnv != rhsEnv {
                return lhsEnv.localizedCaseInsensitiveCompare(rhsEnv) == .orderedAscending
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return .success(sorted)
    }

    private func placeholderServices(for environment: EnvironmentInfo,
                                     services: [ProjectServiceInfo]) -> [ServiceStatus] {
        services.map { service in
            ServiceStatus(id: "\(environment.id):\(service.id)",
                          name: "\(environment.name) / \(service.name)",
                          status: "UNKNOWN",
                          deployedAt: nil,
                          serviceID: service.id,
                          environmentID: environment.id,
                          environmentName: environment.name)
        }
    }

    func parseEnvironmentStatusResponse(data: Data?,
                                        error: Error?,
                                        environment: EnvironmentInfo,
                                        servicesByName: [String: String])
        -> Result<[ServiceStatus], Error> {
        if let apiError = error as? APIError {
            return .failure(apiError)
        }
        if let error {
            return .failure(APIError.network(error.localizedDescription))
        }
        guard let data else {
            return .failure(APIError.parse("Empty response"))
        }

        if let message = graphQLErrorMessage(in: data) {
            if message == "Not Authorized" {
                Config.clearOAuthTokens()
                return .failure(APIError.unauthorized)
            }
            return .failure(APIError.network(message))
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let dataObj = json["data"] as? [String: Any],
            let environmentObject = dataObj["environment"] as? [String: Any]
        else {
            return .failure(APIError.parse("Unexpected response shape"))
        }

        let environmentName = (environmentObject["name"] as? String) ?? environment.name
        let instances = edgeNodes(from: environmentObject["serviceInstances"])
        let services = instances.compactMap { node -> ServiceStatus? in
            guard let instanceID = node["id"] as? String,
                  let serviceName = node["serviceName"] as? String else { return nil }

            let deploymentNode = node["latestDeployment"] as? [String: Any]
            let status = (deploymentNode?["status"] as? String) ?? "UNKNOWN"
            let deployedAt = (deploymentNode?["createdAt"] as? String)
                .flatMap(parseGraphQLDate(_:))
                ?? (deploymentNode?["updatedAt"] as? String).flatMap(parseGraphQLDate(_:))

            let serviceID = servicesByName[serviceName]
            let uniqueID = "\(environment.id):\(serviceID ?? instanceID)"
            let displayName = "\(environmentName) / \(serviceName)"

            return ServiceStatus(id: uniqueID,
                                 name: displayName,
                                 status: status,
                                 deployedAt: deployedAt,
                                 serviceID: serviceID,
                                 environmentID: environment.id,
                                 environmentName: environmentName)
        }
        return .success(services)
    }

    func edgeNodes(from value: Any?) -> [[String: Any]] {
        if let connection = value as? [String: Any],
           let edges = connection["edges"] as? [[String: Any]] {
            return edges.compactMap { $0["node"] as? [String: Any] }
        }
        if let nodes = value as? [[String: Any]] {
            return nodes
        }
        return []
    }

    private func parseGraphQLDate(_ value: String) -> Date? {
        RailwayAPI.fractionalSecondsDateFormatter.date(from: value)
            ?? RailwayAPI.standardDateFormatter.date(from: value)
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
                Diagnostics.shared.log("api", "missing access token", metadata: ["retryingAuth": retryingAuth ? "true" : "false"])
                completion(nil, 0, APIError.unauthorized)
                return
            }

            self.performRequest(query: query, token: token) { data, statusCode, error in
                if self.isUnauthorizedResponse(data: data, statusCode: statusCode), !retryingAuth {
                    Diagnostics.shared.log("api", "unauthorized response, forcing refresh", metadata: ["statusCode": "\(statusCode)"])
                    OAuthManager.shared.refreshToken(force: true) { refreshed in
                        guard refreshed else {
                            Config.clearOAuthTokens()
                            Diagnostics.shared.log("api", "forced refresh failed, clearing tokens", metadata: ["statusCode": "\(statusCode)"])
                            completion(nil, statusCode, APIError.unauthorized)
                            return
                        }
                        Diagnostics.shared.log("api", "forced refresh succeeded", metadata: ["statusCode": "\(statusCode)"])
                        self.performAuthorizedRequest(query: query, retryingAuth: true, completion: completion)
                    }
                    return
                }
                if let error {
                    Diagnostics.shared.log("api", "request failed", metadata: [
                        "statusCode": "\(statusCode)",
                        "error": error.localizedDescription
                    ])
                } else {
                    Diagnostics.shared.log("api", "request completed", metadata: ["statusCode": "\(statusCode)"])
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
