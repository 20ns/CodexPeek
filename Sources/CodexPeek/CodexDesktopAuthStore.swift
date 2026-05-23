import Foundation

final class CodexDesktopAuthStore: @unchecked Sendable {
    private static let uncertainOwnerProfileID = "__codexpeek_uncertain_owner__"

    private let fileManager: FileManager
    private let systemHomeURL: URL
    private let defaultSnapshotURL: URL
    private let ownerStateURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        fileManager: FileManager = .default,
        systemHomeURL: URL = URL(fileURLWithPath: NSString(string: "~/.codex").expandingTildeInPath),
        defaultSnapshotURL: URL = AccountProfileStore.defaultManagedProfilesRootURL()
            .appendingPathComponent("default", isDirectory: true)
            .appendingPathComponent("auth.json"),
        ownerStateURL: URL = AccountProfileStore.baseSupportURL()
            .appendingPathComponent("desktop-auth-owner.json")
    ) {
        self.fileManager = fileManager
        self.systemHomeURL = systemHomeURL
        self.defaultSnapshotURL = defaultSnapshotURL
        self.ownerStateURL = ownerStateURL
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func bootstrapDefaultSnapshotIfNeeded() throws {
        guard !fileManager.fileExists(atPath: defaultSnapshotURL.path) else {
            return
        }

        _ = try syncAuthIfNeeded(from: systemAuthURL, to: defaultSnapshotURL)
    }

    func syncDefaultSnapshotFromSystemAuth() throws {
        _ = try syncAuthIfNeeded(from: systemAuthURL, to: defaultSnapshotURL)
    }

    func shouldSyncDefaultSnapshotFromSystemAuth(among profiles: [AccountProfile]) throws -> Bool {
        try shouldSyncDefaultFromCurrentSystemAuth(among: profiles)
    }

    func accountInfoURL(for profile: AccountProfile, among profiles: [AccountProfile]) throws -> URL {
        let ownerProfileID = try currentOwnerProfileID(among: profiles)

        switch profile.kind {
        case .managed:
            if ownerProfileID == profile.id, fileManager.fileExists(atPath: systemAuthURL.path) {
                return systemAuthURL
            }
            return profile.authURL
        case .systemDefault:
            if ownerProfileID != AccountProfileStore.defaultProfileID,
               fileManager.fileExists(atPath: defaultSnapshotURL.path) {
                return defaultSnapshotURL
            }
            return systemAuthURL
        }
    }

    func reconcileSystemAuth(among profiles: [AccountProfile]) throws {
        let ownerProfileID = try loadOwnerProfileID()
        if let ownerProfileID,
           ownerProfileID != AccountProfileStore.defaultProfileID,
           let owner = profiles.first(where: { $0.id == ownerProfileID && $0.kind == .managed }),
           fileManager.fileExists(atPath: systemAuthURL.path) {
            if try systemAuthBelongs(to: owner) {
                _ = try syncAuthIfNeeded(from: systemAuthURL, to: owner.authURL)
            }
            return
        }

        if let ownerProfileID,
           ownerProfileID != AccountProfileStore.defaultProfileID {
            if let inferredOwnerID = try managedProfileIDMatchingSystemAuth(in: profiles) {
                try saveOwnerProfileID(inferredOwnerID)
            }
            return
        }

        if try shouldSyncDefaultFromCurrentSystemAuth(among: profiles) {
            try syncDefaultSnapshotFromSystemAuth()
        }
    }

    func prepareSystemAuth(for profile: AccountProfile, among profiles: [AccountProfile] = []) throws -> Bool {
        if !profiles.isEmpty {
            try reconcileSystemAuth(among: profiles)
        }

        switch profile.kind {
        case .systemDefault:
            guard fileManager.fileExists(atPath: defaultSnapshotURL.path) else {
                throw CodexUsageError.invalidResponse("Default account is not signed in")
            }
            let changed = try syncAuthIfNeeded(from: defaultSnapshotURL, to: systemAuthURL)
            try saveOwnerProfileID(profile.id)
            return changed
        case .managed:
            guard fileManager.fileExists(atPath: profile.authURL.path) else {
                throw CodexUsageError.invalidResponse("Selected account is not signed in")
            }
            if try shouldSyncDefaultFromCurrentSystemAuth(among: profiles) {
                try syncDefaultSnapshotFromSystemAuth()
            }
            let changed = try syncAuthIfNeeded(from: profile.authURL, to: systemAuthURL)
            try saveOwnerProfileID(profile.id)
            return changed
        }
    }

    func restoreDefaultIfSystemAuthOwned(by profile: AccountProfile, among profiles: [AccountProfile]) throws -> Bool {
        guard try currentOwnerProfileID(among: profiles) == profile.id else {
            return false
        }

        return try prepareSystemAuth(
            for: AccountProfileStore.defaultProfile(),
            among: profiles
        )
    }

    func clearOwnerIfNeeded(for profile: AccountProfile, among profiles: [AccountProfile]) throws {
        if try currentOwnerProfileID(among: profiles) == profile.id {
            try saveOwnerProfileID(AccountProfileStore.defaultProfileID)
        }
    }

    func clearPersistedAuth(for profile: AccountProfile, among profiles: [AccountProfile]) throws {
        switch profile.kind {
        case .systemDefault:
            try removeFileIfExists(at: defaultSnapshotURL)
            try saveOwnerProfileID(AccountProfileStore.defaultProfileID)
        case .managed:
            if try currentOwnerProfileID(among: profiles) == profile.id {
                _ = try restoreDefaultIfSystemAuthOwned(by: profile, among: profiles)
            }
            try removeFileIfExists(at: profile.authURL)
        }
    }

    private var systemAuthURL: URL {
        systemHomeURL.appendingPathComponent("auth.json")
    }

    private func shouldSyncDefaultFromCurrentSystemAuth(among profiles: [AccountProfile]) throws -> Bool {
        guard fileManager.fileExists(atPath: systemAuthURL.path) else {
            return false
        }

        if let ownerProfileID = try loadOwnerProfileID(),
           ownerProfileID != AccountProfileStore.defaultProfileID {
            return false
        }

        return try managedProfileIDMatchingSystemAuth(in: profiles) == nil
    }

    private func currentOwnerProfileID(among profiles: [AccountProfile]) throws -> String {
        if let ownerProfileID = try loadOwnerProfileID() {
            return ownerProfileID
        }

        if let managedProfileID = try managedProfileIDMatchingSystemAuth(in: profiles) {
            return managedProfileID
        }

        return AccountProfileStore.defaultProfileID
    }

    private func managedProfileIDMatchingSystemAuth(in profiles: [AccountProfile]) throws -> String? {
        guard fileManager.fileExists(atPath: systemAuthURL.path) else {
            return nil
        }

        let systemAuthData = try Data(contentsOf: systemAuthURL)
        for profile in profiles where profile.kind == .managed {
            guard fileManager.fileExists(atPath: profile.authURL.path) else {
                continue
            }

            let managedAuthData = try Data(contentsOf: profile.authURL)
            if managedAuthData == systemAuthData {
                return profile.id
            }
        }

        let systemSnapshot = try? AuthJSONAccountInfoSource(authURL: systemAuthURL, fileManager: fileManager).loadAccountSnapshot()
        guard let systemSnapshot, systemSnapshot.isSignedIn else {
            return nil
        }

        for profile in profiles where profile.kind == .managed {
            let managedSnapshot = try? AuthJSONAccountInfoSource(authURL: profile.authURL, fileManager: fileManager).loadAccountSnapshot()
            if managedSnapshot?.matchesIdentity(of: systemSnapshot) == true {
                return profile.id
            }
        }

        return nil
    }

    private func systemAuthBelongs(to profile: AccountProfile) throws -> Bool {
        guard fileManager.fileExists(atPath: profile.authURL.path) else {
            return false
        }

        let systemAuthData = try Data(contentsOf: systemAuthURL)
        let profileAuthData = try Data(contentsOf: profile.authURL)
        if systemAuthData == profileAuthData {
            return true
        }

        let systemSnapshot = try? AuthJSONAccountInfoSource(authURL: systemAuthURL, fileManager: fileManager).loadAccountSnapshot()
        let profileSnapshot = try? AuthJSONAccountInfoSource(authURL: profile.authURL, fileManager: fileManager).loadAccountSnapshot()
        return systemSnapshot?.matchesIdentity(of: profileSnapshot ?? .empty) == true
    }

    private func loadOwnerProfileID() throws -> String? {
        guard fileManager.fileExists(atPath: ownerStateURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: ownerStateURL)
            return try decoder.decode(DesktopAuthOwnerState.self, from: data).profileID
        } catch {
            try quarantineCorruptFile(at: ownerStateURL)
            try saveOwnerProfileID(Self.uncertainOwnerProfileID)
            return Self.uncertainOwnerProfileID
        }
    }

    private func saveOwnerProfileID(_ profileID: String) throws {
        try createPrivateDirectory(at: ownerStateURL.deletingLastPathComponent())

        let data = try encoder.encode(DesktopAuthOwnerState(profileID: profileID))
        try data.write(to: ownerStateURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ownerStateURL.path)
    }

    private func syncAuthIfNeeded(from sourceURL: URL, to destinationURL: URL) throws -> Bool {
        let sourceExists = fileManager.fileExists(atPath: sourceURL.path)
        let destinationExists = fileManager.fileExists(atPath: destinationURL.path)

        guard sourceExists else {
            return false
        }

        let sourceData = try Data(contentsOf: sourceURL)
        if destinationExists {
            let destinationData = try Data(contentsOf: destinationURL)
            if destinationData == sourceData {
                return false
            }
        }

        try createPrivateDirectory(at: destinationURL.deletingLastPathComponent())
        try sourceData.write(to: destinationURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationURL.path)
        return true
    }

    private func createPrivateDirectory(at url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func removeFileIfExists(at url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func quarantineCorruptFile(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }

        let quarantineURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).bad-\(Int(Date().timeIntervalSince1970))")
        try? fileManager.removeItem(at: quarantineURL)
        try fileManager.moveItem(at: url, to: quarantineURL)
    }
}

private struct DesktopAuthOwnerState: Codable {
    var profileID: String
}
