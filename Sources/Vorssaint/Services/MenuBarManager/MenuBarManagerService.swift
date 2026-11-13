// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine
import Foundation
import os.log

/// Which of the three Bartender-style zones a menu-bar extra belongs to.
enum MenuBarSection: String, CaseIterable, Hashable, Codable {
    case visible
    case hidden
    case alwaysHidden
}

/// The chevron's live visibility choice for the two hidden zones. Flipped by
/// clicking the control item.
enum MenuBarChevronState: Equatable {
    /// Hidden icons are being shown (chevron pointing into the bar).
    case showsItems
    /// Hidden icons are tucked away (chevron collapsing them).
    case hidesItems
}

/// Persisted assignment of extras to one of the three zones + the
/// enable/disable feature flag.
@MainActor
final class MenuBarLayoutModel: ObservableObject {
    static let shared = MenuBarLayoutModel()

    @Published private(set) var visible: [String] = []
    @Published private(set) var hidden: [String] = []
    @Published private(set) var alwaysHidden: [String] = []

    private let defaults = UserDefaults.standard
    private let visibleKey = "menuBarManager.section.visible"
    private let hiddenKey = "menuBarManager.section.hidden"
    private let alwaysHiddenKey = "menuBarManager.section.alwaysHidden"

    private init() {
        visible = defaults.stringArray(forKey: visibleKey) ?? []
        hidden = defaults.stringArray(forKey: hiddenKey) ?? []
        alwaysHidden = defaults.stringArray(forKey: alwaysHiddenKey) ?? []
    }

    func section(for key: String) -> MenuBarSection {
        if alwaysHidden.contains(key) { return .alwaysHidden }
        if hidden.contains(key) { return .hidden }
        return .visible
    }

    func keys(in section: MenuBarSection) -> [String] {
        switch section {
        case .visible: return visible
        case .hidden: return hidden
        case .alwaysHidden: return alwaysHidden
        }
    }

    /// Move an extra into one zone. Removes it from every other zone first,
    /// so an item is in exactly one list.
    func assign(_ key: String, to section: MenuBarSection) {
        visible.removeAll { $0 == key }
        hidden.removeAll { $0 == key }
        alwaysHidden.removeAll { $0 == key }
        switch section {
        case .visible: visible.append(key)
        case .hidden: hidden.append(key)
        case .alwaysHidden: alwaysHidden.append(key)
        }
        persist()
    }

    func clear(_ key: String) {
        visible.removeAll { $0 == key }
        hidden.removeAll { $0 == key }
        alwaysHidden.removeAll { $0 == key }
        persist()
    }

    /// Which persistence keys the cover window must paint over for the given
    /// chevron state. Visible items never hide; Always-Hidden items only hide
    /// when the chevron collapses the always-hidden zone too.
    func hiddenPersistenceKeys(chevron: MenuBarChevronState,
                               alwaysHiddenCollapsed: Bool) -> Set<String> {
        var keys = Set<String>()
        if chevron == .hidesItems {
            keys.formUnion(hidden)
        }
        if alwaysHiddenCollapsed {
            keys.formUnion(alwaysHidden)
        }
        return keys
    }

    /// Convenience that pulls the live chevron state from the manager.
    func hiddenPersistenceKeys() -> Set<String> {
        hiddenPersistenceKeys(chevron: MenuBarManagerService.shared.chevronState,
                              alwaysHiddenCollapsed: MenuBarManagerService.shared.alwaysHiddenCollapsed)
    }

    private func persist() {
        defaults.set(visible, forKey: visibleKey)
        defaults.set(hidden, forKey: hiddenKey)
        defaults.set(alwaysHidden, forKey: alwaysHiddenKey)
    }
}

/// Top-level owner of the menu-bar manager module. Starts the capture
/// pipeline, cover coordinator and chevron control item when the feature is
/// enabled, and tears them down when it is not.
@MainActor
final class MenuBarManagerService: ObservableObject {
    static let shared = MenuBarManagerService()

    @Published private(set) var chevronState: MenuBarChevronState = .hidesItems
    /// Whether the "always hidden" group is currently collapsed (icons covered)
    /// as opposed to the user having opt-click/right-click revealed it.
    @Published private(set) var alwaysHiddenCollapsed: Bool = true

    private let log = Logger(subsystem: "com.vorssaint.utils", category: "menubar.manager")
    private var controlItem: MenuBarControlItem?
    private var cancellables = Set<AnyCancellable>()
    private var currentlyEnabled = false

    static let featureAvailabilityKey = "featureAvailable.menuBarManager"

    private init() {}

    /// Feature flag — persisted so a user who hid every icon can still bring
    /// them back by relaunching after flipping this bit off.
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.featureAvailabilityKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.featureAvailabilityKey)
            sync()
        }
    }

    func syncAtLaunch() {
        sync()
    }

    /// Idempotent install/teardown based on the feature flag.
    func sync() {
        let enabled = isEnabled
        if enabled, !currentlyEnabled {
            install()
        } else if !enabled, currentlyEnabled {
            teardown()
        }
        currentlyEnabled = enabled
    }

    private func install() {
        log.debug("Installing menu bar manager")
        MenuBarCoverCoordinator.shared.start()
        let item = MenuBarControlItem()
        item.onToggleHidden = { [weak self] in self?.toggleHidden() }
        item.onToggleAlwaysHidden = { [weak self] in self?.toggleAlwaysHidden() }
        item.install()
        controlItem = item
        applyPhysicalState()
    }

    private func teardown() {
        log.debug("Tearing down menu bar manager")
        controlItem?.uninstall()
        controlItem = nil
        MenuBarCoverCoordinator.shared.stop()
        MenuBarCaptureSession.shared.stop()
    }

    private func toggleHidden() {
        chevronState = (chevronState == .showsItems) ? .hidesItems : .showsItems
        applyPhysicalState()
    }

    private func toggleAlwaysHidden() {
        alwaysHiddenCollapsed.toggle()
        applyPhysicalState()
    }

    /// Reconciliation hook — flips the chevron glyph, re-paints the covers.
    func applyPhysicalState() {
        controlItem?.render(chevron: chevronState)
        MenuBarCoverCoordinator.shared.reconcile()
    }
}
