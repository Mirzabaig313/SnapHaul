// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//

import Foundation
import os

/// Persists ingest profiles to UserDefaults.
///
/// Profiles are small JSON objects — UserDefaults is appropriate.
/// Shared via app group so extensions can read them.
///
/// Thread safety: All access is expected to go through `AppState`
/// which is `@MainActor`-isolated. Do not call from background threads.
struct ProfileStore {
    private static let key = "com.snaphaul.ingestProfiles"
    private let logger = Logger(subsystem: "com.snaphaul.app", category: "profiles")

    func loadAll() -> [IngestProfile] {
        guard let data = UserDefaults.standard.data(forKey: Self.key) else {
            return []
        }
        do {
            return try JSONDecoder().decode([IngestProfile].self, from: data)
        } catch {
            logger.error("Failed to decode profiles: \(error.localizedDescription)")
            // Back up the corrupted data before clearing, so it can be inspected.
            let backupKey = Self.key + ".corrupt.\(Int(Date().timeIntervalSince1970))"
            UserDefaults.standard.set(data, forKey: backupKey)
            logger.error("Corrupted profile data backed up under key: \(backupKey)")
            // Clear the bad data so the app doesn't fail on every launch.
            UserDefaults.standard.removeObject(forKey: Self.key)
            return []
        }
    }

    func saveAll(_ profiles: [IngestProfile]) {
        do {
            let data = try JSONEncoder().encode(profiles)
            UserDefaults.standard.set(data, forKey: Self.key)
        } catch {
            logger.error("Failed to encode profiles: \(error.localizedDescription)")
        }
    }

    func add(_ profile: IngestProfile) {
        var profiles = loadAll()
        profiles.append(profile)
        saveAll(profiles)
    }

    func update(_ profile: IngestProfile) {
        var profiles = loadAll()
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
            saveAll(profiles)
        }
    }

    func delete(id: UUID) {
        var profiles = loadAll()
        profiles.removeAll { $0.id == id }
        saveAll(profiles)
    }
}
