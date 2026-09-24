// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint Menu-Bar-Manager Fork (CH4RL3I)
//
// Ported from jordanbaird/Ice (GPL-3.0-or-later)
// https://github.com/jordanbaird/Ice/blob/main/Ice/MenuBar/MenuBarSection.swift
//
// Section-Modell für Menu-Bar-Icon-Management. Ice unterscheidet drei
// Sektionen; wir übernehmen die Semantik 1:1:
//
//   .visible       — Icons IMMER sichtbar (linke Sektion, unbeschränkt).
//   .hidden        — Icons hinter einem Chevron-Trenner versteckt; auf Klick
//                    aufklappbar. Bartenders "Hidden Items".
//   .alwaysHidden  — Icons NIE automatisch sichtbar; nur über Hotkey oder
//                    Cmd-Klick zeigbar. Bartenders "Always Hidden".
//
// Die konkrete Zuordnung (welches Icon in welche Sektion) speichert der
// MenuBarManagerService in UserDefaults; die Sektion selbst ist nur die
// Container-Definition + der Trenner-Item.
//
// TODO Phase 3: ControlItem (der Trenner-Icon in der Menü-Bar) portieren aus
// Ice/MenuBar/ControlItem/. Aktuell nur Enum + Metadaten.

import Foundation

public enum MenuBarSectionName: String, CaseIterable, Codable, Sendable {
    case visible
    case hidden
    case alwaysHidden

    /// Angezeigter Name in der UI.
    public var displayString: String {
        switch self {
        case .visible: "Visible"
        case .hidden: "Hidden"
        case .alwaysHidden: "Always-Hidden"
        }
    }

    /// Stable Identifier für UserDefaults-Persistierung.
    public var defaultsKey: String {
        "menuBarManager.section.\(rawValue)"
    }
}

/// Repräsentiert eine Sektion der Menü-Bar mit den ihr zugeordneten Icons
/// (referenziert per NSStatusItem-Titel oder Bundle-ID, siehe MenuBarItem).
public struct MenuBarSection: Identifiable, Sendable {
    public let id: MenuBarSectionName
    public var itemIdentifiers: [String]  // Placeholder — später MenuBarItem-Refs

    public init(id: MenuBarSectionName, itemIdentifiers: [String] = []) {
        self.id = id
        self.itemIdentifiers = itemIdentifiers
    }
}
