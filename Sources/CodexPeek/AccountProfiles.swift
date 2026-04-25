import Foundation

enum AccountProfileKind: String, Codable, Equatable {
    case systemDefault
    case managed
}

struct AccountProfile: Codable, Equatable {
    var id: String
    var name: String?
    var homePath: String
    var kind: AccountProfileKind

    var homeURL: URL {
        URL(fileURLWithPath: homePath)
    }

    var authURL: URL {
        homeURL.appendingPathComponent("auth.json")
    }

    var sessionsURL: URL {
        homeURL.appendingPathComponent("sessions", isDirectory: true)
    }

    var displayName: String {
        if let name, !name.isEmpty {
            return name
        }

        switch kind {
        case .systemDefault:
            return "Default Account"
        case .managed:
            return "Account \(shortIdentifier)"
        }
    }

    private var shortIdentifier: String {
        String(id.prefix(6)).uppercased()
    }
}

struct AccountProfilesState: Codable, Equatable {
    var profiles: [AccountProfile]
    var activeProfileID: String

    func activeProfile() -> AccountProfile? {
        profiles.first { $0.id == activeProfileID }
    }
}

enum DuplicateProfileRecovery {
    static func keeper(
        for profile: AccountProfile,
        snapshot: CodexAccountSnapshot,
        in state: AccountProfilesState,
        snapshotsByProfileID: [String: CodexAccountSnapshot],
        pendingCreatedProfileIDs: Set<String> = []
    ) -> AccountProfile? {
        state.profiles
            .filter { $0.id != profile.id }
            .filter { otherProfile in
                guard let otherSnapshot = snapshotsByProfileID[otherProfile.id] else {
                    return false
                }
                return otherSnapshot.matchesIdentity(of: snapshot)
            }
            .sorted { lhs, rhs in
                if lhs.kind != rhs.kind {
                    return lhs.kind == .systemDefault
                }
                let lhsWasNew = pendingCreatedProfileIDs.contains(lhs.id)
                let rhsWasNew = pendingCreatedProfileIDs.contains(rhs.id)
                if lhsWasNew != rhsWasNew {
                    return !lhsWasNew
                }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            .first
    }

    static func candidateProfiles(
        from state: AccountProfilesState,
        activeProfile: AccountProfile,
        snapshotsByProfileID: [String: CodexAccountSnapshot]
    ) -> [AccountProfile] {
        guard activeProfile.kind == .managed,
              let activeSnapshot = snapshotsByProfileID[activeProfile.id],
              activeSnapshot.isSignedIn else {
            return []
        }

        return state.profiles
            .filter { $0.id != activeProfile.id }
            .filter { profile in
                guard let snapshot = snapshotsByProfileID[profile.id] else {
                    return false
                }
                return snapshot.matchesIdentity(of: activeSnapshot)
            }
            .sorted { lhs, rhs in
                if lhs.kind != rhs.kind {
                    return lhs.kind == .systemDefault
                }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }
}

final class AccountProfileStore: @unchecked Sendable {
    static let defaultProfileID = "default"

    private let stateURL: URL
    private let managedProfilesRootURL: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        stateURL: URL = AccountProfileStore.defaultStateURL(),
        managedProfilesRootURL: URL = AccountProfileStore.defaultManagedProfilesRootURL(),
        fileManager: FileManager = .default
    ) {
        self.stateURL = stateURL
        self.managedProfilesRootURL = managedProfilesRootURL
        self.fileManager = fileManager
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func loadState() throws -> AccountProfilesState {
        if !fileManager.fileExists(atPath: stateURL.path) {
            let state = normalized(bootstrapState())
            try saveState(state)
            return state
        }

        let data = try Data(contentsOf: stateURL)
        let state = try decoder.decode(AccountProfilesState.self, from: data)
        let normalizedState = normalized(state)
        if normalizedState != state {
            try saveState(normalizedState)
        }
        return normalizedState
    }

    func setActiveProfileID(_ profileID: String) throws -> AccountProfilesState {
        var state = try loadState()
        guard state.profiles.contains(where: { $0.id == profileID }) else {
            throw CodexUsageError.invalidResponse("unknown account profile")
        }

        state.activeProfileID = profileID
        try saveState(state)
        return state
    }

    func createManagedProfile(name: String? = nil, activate: Bool) throws -> AccountProfilesState {
        var state = try loadState()
        let profileID = UUID().uuidString.lowercased()
        let profileRootURL = managedProfilesRootURL.appendingPathComponent(profileID, isDirectory: true)

        try fileManager.createDirectory(at: profileRootURL, withIntermediateDirectories: true)

        let profile = AccountProfile(
            id: profileID,
            name: name,
            homePath: profileRootURL.path,
            kind: .managed
        )

        state.profiles.append(profile)
        if activate {
            state.activeProfileID = profileID
        }

        try saveState(state)
        return state
    }

    func renameProfile(id profileID: String, name: String?) throws -> AccountProfilesState {
        var state = try loadState()
        guard let index = state.profiles.firstIndex(where: { $0.id == profileID }) else {
            throw CodexUsageError.invalidResponse("unknown account profile")
        }

        guard state.profiles[index].kind == .managed else {
            return state
        }

        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        state.profiles[index].name = trimmedName?.isEmpty == false ? trimmedName : nil
        try saveState(state)
        return state
    }

    func deleteManagedProfile(id profileID: String) throws -> AccountProfilesState {
        var state = try loadState()
        guard let index = state.profiles.firstIndex(where: { $0.id == profileID }) else {
            throw CodexUsageError.invalidResponse("unknown account profile")
        }

        let profile = state.profiles[index]
        guard profile.kind == .managed else {
            throw CodexUsageError.invalidResponse("default account cannot be removed")
        }

        state.profiles.remove(at: index)
        if state.activeProfileID == profileID {
            state.activeProfileID = Self.defaultProfileID
        }

        try saveState(state)
        if fileManager.fileExists(atPath: profile.homeURL.path) {
            try fileManager.removeItem(at: profile.homeURL)
        }
        return try loadState()
    }

    private func saveState(_ state: AccountProfilesState) throws {
        try fileManager.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: managedProfilesRootURL,
            withIntermediateDirectories: true
        )

        let data = try encoder.encode(state)
        try data.write(to: stateURL, options: .atomic)
    }

    private func bootstrapState() -> AccountProfilesState {
        AccountProfilesState(
            profiles: [Self.defaultProfile()],
            activeProfileID: Self.defaultProfileID
        )
    }

    private func normalized(_ state: AccountProfilesState) -> AccountProfilesState {
        var profiles = state.profiles
        if let defaultIndex = profiles.firstIndex(where: { $0.id == Self.defaultProfileID }) {
            profiles[defaultIndex] = Self.defaultProfile()
        } else {
            profiles.insert(Self.defaultProfile(), at: 0)
        }

        let activeProfileID: String
        if profiles.contains(where: { $0.id == state.activeProfileID }) {
            activeProfileID = state.activeProfileID
        } else {
            activeProfileID = Self.defaultProfileID
        }

        let sortedProfiles = profiles.sorted { lhs, rhs in
            if lhs.id == Self.defaultProfileID {
                return true
            }
            if rhs.id == Self.defaultProfileID {
                return false
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }

        return AccountProfilesState(
            profiles: sortedProfiles,
            activeProfileID: activeProfileID
        )
    }

    static func defaultProfile() -> AccountProfile {
        AccountProfile(
            id: Self.defaultProfileID,
            name: nil,
            homePath: NSString(string: "~/.codex").expandingTildeInPath,
            kind: .systemDefault
        )
    }

    static func defaultStateURL() -> URL {
        baseSupportURL().appendingPathComponent("accounts.json")
    }

    static func defaultManagedProfilesRootURL() -> URL {
        baseSupportURL().appendingPathComponent("Profiles", isDirectory: true)
    }

    static func baseSupportURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("CodexPeek", isDirectory: true)
    }
}
