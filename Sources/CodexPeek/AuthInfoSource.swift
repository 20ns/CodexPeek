import Foundation

protocol AccountInfoSource: Sendable {
    func loadAccountSnapshot() throws -> CodexAccountSnapshot?
}

final class AuthJSONAccountInfoSource: AccountInfoSource, @unchecked Sendable {
    private let authURL: URL
    private let fileManager: FileManager

    init(
        authURL: URL = URL(fileURLWithPath: NSString(string: "~/.codex/auth.json").expandingTildeInPath),
        fileManager: FileManager = .default
    ) {
        self.authURL = authURL
        self.fileManager = fileManager
    }

    func loadAccountSnapshot() throws -> CodexAccountSnapshot? {
        guard fileManager.fileExists(atPath: authURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: authURL)
        let auth = try JSONDecoder().decode(AuthJSONDocument.self, from: data)

        let authMode = CodexAuthMode(rawValue: auth.authMode ?? "") ?? .unknown
        let tokenPayload = try auth.tokens?.idToken.flatMap(parseJWT)

        let email = tokenPayload?.email
        let planType = CodexPlanType(rawValue: tokenPayload?.openAI?.chatGPTPlanType ?? "") ?? .unknown

        if email == nil, authMode == .unknown, planType == .unknown {
            return nil
        }

        return CodexAccountSnapshot(
            email: email,
            authMode: authMode,
            planType: planType
        )
    }

    private func parseJWT(_ token: String) throws -> AuthJWTPayload {
        let segments = token.split(separator: ".")
        guard segments.count > 1 else {
            throw CodexUsageError.invalidResponse("invalid id_token")
        }

        var payload = String(segments[1])
        let remainder = payload.count % 4
        if remainder != 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")) else {
            throw CodexUsageError.invalidResponse("invalid id_token payload")
        }

        return try JSONDecoder().decode(AuthJWTPayload.self, from: data)
    }
}

private struct AuthJSONDocument: Decodable {
    let authMode: String?
    let tokens: AuthJSONTokens?

    private enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case tokens
    }
}

private struct AuthJSONTokens: Decodable {
    let idToken: String?

    private enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
    }
}

private struct AuthJWTPayload: Decodable {
    let email: String?
    let openAI: OpenAIAuthPayload?

    private enum CodingKeys: String, CodingKey {
        case email
        case openAI = "https://api.openai.com/auth"
    }
}

private struct OpenAIAuthPayload: Decodable {
    let chatGPTPlanType: String?

    private enum CodingKeys: String, CodingKey {
        case chatGPTPlanType = "chatgpt_plan_type"
    }
}
