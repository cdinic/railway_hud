import XCTest
@testable import RailwayHUD

final class RailwayAPITests: XCTestCase {
    private let api = RailwayAPI()

    func testParseProjectTopologyResponseExtractsServicesAndEnvironments() throws {
        let data = try jsonData([
            "data": [
                "project": [
                    "services": [
                        "edges": [
                            ["node": ["id": "svc-main", "name": "main"]],
                            ["node": ["id": "svc-db", "name": "postgres"]],
                            ["node": ["id": "svc-site", "name": "marketing"]]
                        ]
                    ],
                    "environments": [
                        "edges": [
                            ["node": ["id": "env-prod", "name": "production"]],
                            ["node": ["id": "env-dev", "name": "development"]]
                        ]
                    ]
                ]
            ]
        ])

        let result = api.parseProjectTopologyResponse(data: data, error: nil)

        switch result {
        case .success(let topology):
            XCTAssertEqual(topology.services.map(\.name), ["main", "postgres", "marketing"])
            XCTAssertEqual(topology.environments.map(\.name), ["production", "development"])
            XCTAssertEqual(topology.servicesByName["main"], "svc-main")
            XCTAssertEqual(topology.servicesByName["postgres"], "svc-db")
        case .failure(let error):
            XCTFail("Expected successful topology parse, got \(error)")
        }
    }

    func testParseEnvironmentStatusResponseBuildsEnvironmentScopedRows() throws {
        let data = try jsonData([
            "data": [
                "environment": [
                    "id": "env-prod",
                    "name": "production",
                    "serviceInstances": [
                        "edges": [
                            ["node": [
                                "id": "instance-main",
                                "serviceName": "main",
                                "latestDeployment": [
                                    "status": "SUCCESS",
                                    "createdAt": "2026-03-18T10:00:00Z",
                                    "updatedAt": "2026-03-18T10:01:00Z"
                                ]
                            ]],
                            ["node": [
                                "id": "instance-db",
                                "serviceName": "postgres",
                                "latestDeployment": [
                                    "status": "DEPLOYING",
                                    "createdAt": "2026-03-18T09:00:00Z"
                                ]
                            ]]
                        ]
                    ]
                ]
            ]
        ])

        let result = api.parseEnvironmentStatusResponse(
            data: data,
            error: nil,
            environment: EnvironmentInfo(id: "env-prod", name: "production"),
            servicesByName: ["main": "svc-main", "postgres": "svc-db"]
        )

        switch result {
        case .success(let services):
            XCTAssertEqual(services.count, 2)
            XCTAssertEqual(services[0].id, "env-prod:svc-main")
            XCTAssertEqual(services[0].name, "production / main")
            XCTAssertEqual(services[0].serviceID, "svc-main")
            XCTAssertEqual(services[0].environmentID, "env-prod")
            XCTAssertNotNil(services[0].deployedAt)
            XCTAssertEqual(services[1].id, "env-prod:svc-db")
            XCTAssertEqual(services[1].status, "DEPLOYING")
        case .failure(let error):
            XCTFail("Expected successful environment parse, got \(error)")
        }
    }

    func testMergeEnvironmentStatusesKeepsSuccessfulEnvironmentAndSynthesizesGrayPlaceholdersForFailures() {
        let services = [
            ProjectServiceInfo(id: "svc-main", name: "main"),
            ProjectServiceInfo(id: "svc-db", name: "postgres"),
            ProjectServiceInfo(id: "svc-site", name: "marketing")
        ]

        let prodRows = [
            ServiceStatus(id: "env-prod:svc-main", name: "production / main", status: "SUCCESS", deployedAt: nil, serviceID: "svc-main", environmentID: "env-prod", environmentName: "production"),
            ServiceStatus(id: "env-prod:svc-db", name: "production / postgres", status: "SUCCESS", deployedAt: nil, serviceID: "svc-db", environmentID: "env-prod", environmentName: "production"),
            ServiceStatus(id: "env-prod:svc-site", name: "production / marketing", status: "SUCCESS", deployedAt: nil, serviceID: "svc-site", environmentID: "env-prod", environmentName: "production")
        ]

        let results = [
            EnvironmentStatusFetchResult(environment: EnvironmentInfo(id: "env-prod", name: "production"),
                                         services: prodRows,
                                         error: nil),
            EnvironmentStatusFetchResult(environment: EnvironmentInfo(id: "env-dev", name: "development"),
                                         services: [],
                                         error: APIError.network("timed out"))
        ]

        let merged = api.mergeEnvironmentStatuses(results, services: services)

        switch merged {
        case .success(let rows):
            XCTAssertEqual(rows.count, 6)
            let devRows = rows.filter { $0.environmentID == "env-dev" }
            XCTAssertEqual(devRows.count, 3)
            XCTAssertTrue(devRows.allSatisfy { $0.status == "UNKNOWN" })
            XCTAssertEqual(devRows.map(\.name), [
                "development / main",
                "development / marketing",
                "development / postgres"
            ])
        case .failure(let error):
            XCTFail("Expected partial success with placeholders, got \(error)")
        }
    }

    func testMergeEnvironmentStatusesFailsWhenAllEnvironmentsFail() {
        let results = [
            EnvironmentStatusFetchResult(environment: EnvironmentInfo(id: "env-prod", name: "production"),
                                         services: [],
                                         error: APIError.network("timed out")),
            EnvironmentStatusFetchResult(environment: EnvironmentInfo(id: "env-dev", name: "development"),
                                         services: [],
                                         error: APIError.network("timed out"))
        ]

        let merged = api.mergeEnvironmentStatuses(results, services: [
            ProjectServiceInfo(id: "svc-main", name: "main")
        ])

        switch merged {
        case .success(let rows):
            XCTFail("Expected failure when every environment fails, got \(rows.count) rows")
        case .failure(let error):
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }
    }

    private func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
