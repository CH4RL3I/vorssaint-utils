// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine
import CoreGraphics
import Foundation

/// Persistent dictionary from icon hash → user-chosen display name. The chip
/// view asks this store first; only when nothing matches does it fall back to
/// the generic "MenuBarAgent #N" label.
///
/// Rows survive relaunches via UserDefaults. Matching is tolerant: an exact
/// hash hit wins, otherwise we accept the closest stored entry whose Hamming
/// distance is ≤ 6 bits (same tolerance Bartender's icon store uses).
@MainActor
final class MenuBarIdentityStore: ObservableObject {
    static let shared = MenuBarIdentityStore()

    @Published private(set) var entries: [String: String] = [:]

    private let defaults = UserDefaults.standard
    private let storeKey = "menuBarManager.identity.hashes"

    private init() {
        var loaded = defaults.dictionary(forKey: storeKey) as? [String: String] ?? [:]
        // Purge any legacy "0" entry — it stamped every failed crop with the
        // same name until the fix above landed, and would keep doing so until
        // the user cleared it manually.
        if loaded.removeValue(forKey: "0") != nil {
            defaults.set(loaded, forKey: storeKey)
        }
        entries = loaded
    }

    /// Look up a display name for an icon hash. Exact hit wins; otherwise the
    /// closest stored entry within 3 bits of Hamming distance (tight enough
    /// that unrelated icons stay distinct, loose enough that a battery-level
    /// pixel shift still matches). The previous tolerance of 6 bits collapsed
    /// every MenuBarAgent slot into one; dropping to 0 made real captures
    /// miss when the icon flickers by a pixel. 3 is the sweet spot.
    /// Hash 0 is treated as "unresolved" — it comes from a failed crop.
    func name(for hash: UInt64) -> String? {
        guard hash != 0 else { return nil }
        let exactKey = MenuBarIconHasher.hexKey(for: hash)
        if let hit = entries[exactKey] { return hit }
        var bestName: String?
        var bestDistance = Int.max
        for (key, name) in entries {
            guard let other = UInt64(key, radix: 16), other != 0 else { continue }
            let d = MenuBarIconHasher.hamming(hash, other)
            if d < bestDistance {
                bestDistance = d
                bestName = name
            }
        }
        return bestDistance <= 3 ? bestName : nil
    }

    /// Save a human-readable name for an icon hash. An empty name forgets the
    /// entry. A hash of 0 is rejected: it came from a failed crop and would
    /// stamp every other failed crop with the same name.
    func set(_ name: String, forHash hash: UInt64) {
        guard hash != 0 else { return }
        write(name, forKey: MenuBarIconHasher.hexKey(for: hash))
    }

    /// Persistence-key fallback: used when no icon crop is available (e.g. the
    /// slot's host window isn't being captured yet, as happens for external
    /// displays before Phase B gains per-display coverage). Prefixed with
    /// `k:` so it can't collide with a hex-form hash key, which is always
    /// digits-and-a-f only.
    func name(forPersistenceKey key: String) -> String? {
        entries["k:" + key]
    }

    func set(_ name: String, forPersistenceKey key: String) {
        write(name, forKey: "k:" + key)
    }

    private func write(_ name: String, forKey key: String) {
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            entries.removeValue(forKey: key)
        } else {
            entries[key] = name
        }
        defaults.set(entries, forKey: storeKey)
    }
}
