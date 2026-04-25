import Foundation

struct AppServerRateLimitsResponse: Decodable {
    let rateLimits: AppServerRateLimitSnapshot
    let rateLimitsByLimitId: [String: AppServerRateLimitSnapshot]?
}

struct AppServerRateLimitSnapshot: Decodable, Equatable {
    let limitId: String?
    let limitName: String?
    let primary: AppServerRateLimitWindow?
    let secondary: AppServerRateLimitWindow?
    let planType: CodexPlanType?
}

struct AppServerRateLimitWindow: Decodable, Equatable {
    let usedPercent: Int
    let windowDurationMins: Int?
    let resetsAt: Int64?
}

struct AppServerAccountReadResponse: Decodable {
    let account: AppServerAccount?
    let requiresOpenaiAuth: Bool
}

enum AppServerAccount: Decodable, Equatable {
    case apiKey
    case chatgpt(email: String, planType: CodexPlanType)

    private enum CodingKeys: String, CodingKey {
        case type
        case email
        case planType
    }

    private enum Kind: String, Decodable {
        case apiKey
        case chatgpt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(Kind.self, forKey: .type)

        switch type {
        case .apiKey:
            self = .apiKey
        case .chatgpt:
            self = .chatgpt(
                email: try container.decode(String.self, forKey: .email),
                planType: try container.decode(CodexPlanType.self, forKey: .planType)
            )
        }
    }
}

struct AppServerResponseIdentifier: Decodable {
    let id: Int?
}

struct AppServerInitializeResponse: Decodable {
    let userAgent: String
}

struct AppServerTypedEnvelope<Result: Decodable>: Decodable {
    let id: Int
    let result: Result?
    let error: AppServerErrorPayload?
}

struct AppServerErrorPayload: Decodable {
    let message: String
}

enum AppServerLineParser {
    static func decodeIdentifier(from line: String) throws -> AppServerResponseIdentifier {
        try JSONDecoder().decode(AppServerResponseIdentifier.self, from: Data(line.utf8))
    }

    static func decode<Result: Decodable>(_ type: Result.Type, from line: String) throws -> AppServerTypedEnvelope<Result> {
        try JSONDecoder().decode(AppServerTypedEnvelope<Result>.self, from: Data(line.utf8))
    }
}

enum AppServerRateLimitSelector {
    static func selectCodexSnapshot(from response: AppServerRateLimitsResponse) -> AppServerRateLimitSnapshot {
        response.rateLimitsByLimitId?["codex"] ?? response.rateLimits
    }

    static func selectSparkSnapshot(from response: AppServerRateLimitsResponse) -> AppServerRateLimitSnapshot? {
        guard let rateLimitsByLimitId = response.rateLimitsByLimitId else {
            return nil
        }

        if let knownSparkSnapshot = rateLimitsByLimitId["codex_bengalfox"] {
            return knownSparkSnapshot
        }

        return rateLimitsByLimitId.values.first { snapshot in
            let limitName = snapshot.limitName?.localizedLowercase ?? ""
            let limitID = snapshot.limitId?.localizedLowercase ?? ""
            return limitName.contains("spark") || limitID.contains("spark")
        }
    }
}

enum AppServerRequestBuilder {
    static func initializeData() throws -> Data {
        try lineData(for: InitializeRequest())
    }

    static func initializedData() throws -> Data {
        try lineData(for: InitializedNotification())
    }

    static func accountReadData() throws -> Data {
        try lineData(for: AccountReadRequest())
    }

    static func rateLimitsReadData() throws -> Data {
        try lineData(for: AccountRateLimitsReadRequest())
    }

    private static func lineData<T: Encodable>(for request: T) throws -> Data {
        let encoder = JSONEncoder()
        var data = try encoder.encode(request)
        data.append(0x0A)
        return data
    }
}

private struct InitializeRequest: Encodable {
    let method = "initialize"
    let id = 1
    let params = InitializeParams(
        clientInfo: ClientInfo(name: "CodexPeek", version: "0.1.0"),
        capabilities: nil
    )
}

private struct InitializeParams: Encodable {
    let clientInfo: ClientInfo
    let capabilities: [String: String]?
}

private struct ClientInfo: Encodable {
    let name: String
    let version: String
}

private struct InitializedNotification: Encodable {
    let method = "initialized"
}

private struct AccountReadRequest: Encodable {
    let method = "account/read"
    let id = 2
    let params = EmptyObject()
}

private struct AccountRateLimitsReadRequest: Encodable {
    let method = "account/rateLimits/read"
    let id = 3
}

private struct EmptyObject: Encodable {}
