import Foundation

struct ServiceStatus {
    let id: String
    let name: String
    let status: String
}

enum APIError: LocalizedError {
    case noToken
    case network(String)
    case parse(String)

    var errorDescription: String? {
        switch self {
        case .noToken:        return "No token — open API Key in the menu"
        case .network(let m): return "Network: \(m)"
        case .parse(let m):   return "Parse error: \(m)"
        }
    }
}

class RailwayAPI {
    private let apiURL = URL(string: "https://backboard.railway.app/graphql/v2")!

    // Stored once — the query string never changes.
    private lazy var query: String = """
    {
      project(id: "\(Config.projectID)") {
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

    func fetchStatus(completion: @escaping (Result<[ServiceStatus], Error>) -> Void) {
        guard let token = Config.readToken() else {
            completion(.failure(APIError.noToken))
            return
        }

        var request = URLRequest(url: apiURL, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query])

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                completion(.failure(APIError.network(error.localizedDescription))); return
            }
            guard let data = data else {
                completion(.failure(APIError.parse("Empty response"))); return
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errors = json["errors"] as? [[String: Any]],
               let msg = errors.first?["message"] as? String {
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
        }.resume()
    }
}
