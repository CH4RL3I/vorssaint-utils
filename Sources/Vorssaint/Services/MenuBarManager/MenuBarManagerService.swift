// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint Menu-Bar-Manager Fork (CH4RL3I)
//
// Ported from jordanbaird/Ice (GPL-3.0-or-later)
// Basiert konzeptionell auf Ice/MenuBar/MenuBarManager.swift, aber im
// Vorssaint-Stil: `final class … ObservableObject` mit `static let shared`,
// analog zu AppAppearanceController.

import AppKit
import Combine
import Foundation
import SwiftUI

/// Verwaltet die drei Sektionen und ihre Icon-Zuordnung.
///
/// **Phase 2 (aktuell):** Nur State + Persistierung. Icons werden noch nicht
/// tatsächlich manipuliert — dazu braucht es die Accessibility-API-Hooks aus
/// Ice/MenuBar/MenuBarItems/ und optional AXSwift. Ziel dieses Skeletts: der
/// Fork kompiliert MIT der neuen Datei, und die Sektionen sind über
/// UserDefaults abfragbar.
///
/// **Phase 3 (nächster Schritt):** ControlItem (Trenner-Icon) portieren →
/// erste sichtbare Menü-Bar-Änderung.
///
/// **Phase 4:** MenuBarItems (echte Icon-Enumeration + Drag-Reorder) portieren
/// mit AXSwift oder eigenem AX-Wrapper.
@MainActor
public final class MenuBarManagerService: ObservableObject {
    public static let shared = MenuBarManagerService()

    /// Ist das Feature vom User aktiviert? Persistiert in UserDefaults unter
    /// `featureAvailable.menuBarManager` — analog zu Vorssaints anderen Feature-Flags.
    @Published public var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Defaults.enabledKey)
        }
    }

    /// Die drei Sektionen mit ihren aktuell zugewiesenen Item-Identifiern.
    @Published public private(set) var sections: [MenuBarSection]

    private init() {
        // Feature-Flag laden. Default = false, bis der User es aktiviert.
        self.isEnabled = UserDefaults.standard.bool(forKey: Defaults.enabledKey)

        // Sektionen aus UserDefaults hydrieren.
        self.sections = MenuBarSectionName.allCases.map { name in
            let stored = UserDefaults.standard.stringArray(forKey: name.defaultsKey) ?? []
            return MenuBarSection(id: name, itemIdentifiers: stored)
        }
    }

    // MARK: - Icon-Zuweisung

    /// Icon in eine bestimmte Sektion verschieben. Idempotent: erst aus allen
    /// alten Sektionen entfernen, dann in die neue einfügen.
    public func assign(itemIdentifier: String, to sectionName: MenuBarSectionName) {
        for i in sections.indices {
            sections[i].itemIdentifiers.removeAll { $0 == itemIdentifier }
        }
        if let target = sections.firstIndex(where: { $0.id == sectionName }) {
            sections[target].itemIdentifiers.append(itemIdentifier)
            UserDefaults.standard.set(sections[target].itemIdentifiers, forKey: sectionName.defaultsKey)
        }
        // In Phase 3+: nach jeder Zuweisung → ControlItem neu positionieren, um
        // die tatsächliche Menü-Bar-Anzeige zu aktualisieren.
    }

    /// Alle Icons einer Sektion in einer neuen Reihenfolge speichern.
    public func reorder(itemIdentifiers: [String], in sectionName: MenuBarSectionName) {
        guard let idx = sections.firstIndex(where: { $0.id == sectionName }) else { return }
        sections[idx].itemIdentifiers = itemIdentifiers
        UserDefaults.standard.set(itemIdentifiers, forKey: sectionName.defaultsKey)
    }

    /// Vorssaints Standard-Hook. Wird von FeatureRuntime aufgerufen wenn sich
    /// die Feature-Verfügbarkeit ändert (User toggled es in den Settings).
    /// Aktuell (Phase 2) noch No-Op — in Phase 3 wird hier der ControlItem
    /// gestartet/gestoppt und die Icon-Enumeration angeworfen.
    public func syncWithPreferences() {
        // TODO Phase 3: enable → ControlItem einblenden, MenuBarItems-Observer starten
        // TODO Phase 3: disable → ControlItem entfernen, alle Icons in .visible zurückschieben
    }

    // MARK: - UserDefaults-Schlüssel

    enum Defaults {
        static let enabledKey = "featureAvailable.menuBarManager"
    }
}
