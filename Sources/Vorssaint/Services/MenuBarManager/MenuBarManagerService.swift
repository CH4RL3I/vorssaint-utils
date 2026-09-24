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
            reconcileControlItems()
        }
    }

    /// Die drei Sektionen mit ihren aktuell zugewiesenen Item-Identifiern.
    @Published public private(set) var sections: [MenuBarSection]

    /// Die Trenner-Icons in der Menü-Bar. Lazy angelegt beim ersten install.
    private var hiddenSeparator: MenuBarControlItem?
    private var alwaysHiddenSeparator: MenuBarControlItem?

    private init() {
        // Feature-Flag laden. Default = false, bis der User es aktiviert.
        self.isEnabled = UserDefaults.standard.bool(forKey: Defaults.enabledKey)

        // Sektionen aus UserDefaults hydrieren.
        self.sections = MenuBarSectionName.allCases.map { name in
            let stored = UserDefaults.standard.stringArray(forKey: name.defaultsKey) ?? []
            return MenuBarSection(id: name, itemIdentifiers: stored)
        }
        // Beim Start ControlItems ausrichten gemäß aktuellem isEnabled-State.
        reconcileControlItems()
    }

    /// Trenner-Icons in Menü-Bar an/aus schalten passend zum isEnabled-State.
    /// Wenn ge-enabled, wird auch einmalig der Icon-Bestand enumeriert und
    /// als Log ausgegeben (Beweis dass die private CGS-API funktioniert).
    private func reconcileControlItems() {
        if isEnabled {
            if hiddenSeparator == nil {
                hiddenSeparator = MenuBarControlItem(kind: .sectionSeparatorHidden)
            }
            if alwaysHiddenSeparator == nil {
                alwaysHiddenSeparator = MenuBarControlItem(kind: .sectionSeparatorAlwaysHidden)
            }
            hiddenSeparator?.install()
            alwaysHiddenSeparator?.install()
            // Hydrate each separator's toggle-state from what it looked like
            // last time the user quit. Without this, every launch resets to
            // "everything shown" — annoying if you actually want stuff hidden.
            hiddenSeparator?.setState(loadState(for: .sectionSeparatorHidden))
            alwaysHiddenSeparator?.setState(loadState(for: .sectionSeparatorAlwaysHidden))
            // Persist any future toggle. Observing @Published state via
            // Combine keeps it simple; we sink into UserDefaults on change.
            wireStatePersistence(hiddenSeparator, kind: .sectionSeparatorHidden)
            wireStatePersistence(alwaysHiddenSeparator, kind: .sectionSeparatorAlwaysHidden)
            // NSApplication.run() has not yet started when this fires from
            // init() — CGSGetProcessMenuBarWindowList returns 0 items for a
            // process without a menu-bar connection. Defer to first main-loop
            // tick, and again at 3s once other apps' status items have
            // reliably registered.
            DispatchQueue.main.async { [weak self] in self?.discoverAndLogIcons() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.discoverAndLogIcons()
            }
        } else {
            hiddenSeparator?.uninstall()
            alwaysHiddenSeparator?.uninstall()
        }
    }

    // MARK: - Toggle-state persistence

    private var cancellables = Set<AnyCancellable>()

    private func stateKey(for kind: MenuBarControlItem.Kind) -> String {
        "menuBarManager.controlItem.\(kind.rawValue).state"
    }

    private func loadState(for kind: MenuBarControlItem.Kind) -> MenuBarControlItem.HidingState {
        let raw = UserDefaults.standard.string(forKey: stateKey(for: kind)) ?? "showsItems"
        return raw == "hidesItems" ? .hidesItems : .showsItems
    }

    private func wireStatePersistence(
        _ item: MenuBarControlItem?,
        kind: MenuBarControlItem.Kind
    ) {
        guard let item else { return }
        item.$state
            .dropFirst() // first value = initial; not a user change
            .sink { [weak self] newState in
                guard let self else { return }
                let raw = (newState == .hidesItems) ? "hidesItems" : "showsItems"
                UserDefaults.standard.set(raw, forKey: self.stateKey(for: kind))
            }
            .store(in: &cancellables)
    }

    /// Phase 4 milestone: prove that we can see other apps' menu-bar icons.
    /// Prints a compact summary to stderr; a real UI comes in Phase 6.
    public func discoverAndLogIcons() {
        let items = MenuBarEnumerator.snapshot()
        FileHandle.standardError.write(
            Data("[MenuBarManager] discovered \(items.count) menu-bar items:\n".utf8)
        )
        for item in items {
            let line = "  · pid=\(item.ownerPID) owner=\(item.ownerName) title=\"\(item.title)\" x=\(Int(item.frame.minX))\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        // Phase 7 experiment: try to move ONE arbitrary menu-bar item off-screen
        // via CGSMoveWindow. Success would let us skip Ice's 500-LOC event
        // simulation. First item that is owned by Control Center + is titled
        // "Item-0" (anonymous, low blast radius if we accidentally move a real
        // system icon).
        guard let victim = items.first(where: { $0.ownerName == "Control Center" && $0.title == "Item-0" }) else {
            return
        }
        let originalX = Int(victim.frame.minX)
        let target = CGPoint(x: -500, y: 0)
        let code = vmb_tryMoveMenuBarItem(victim.windowID, to: target)
        FileHandle.standardError.write(Data(
            "[MoveTest] CGSMoveWindow(wid=\(victim.windowID) from x=\(originalX) to x=-500) → \(code)\n".utf8
        ))
        // Wait 500ms, re-enumerate, see if x actually changed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let after = MenuBarEnumerator.snapshot()
            if let sameItem = after.first(where: { $0.windowID == victim.windowID }) {
                FileHandle.standardError.write(Data(
                    "[MoveTest] after: wid=\(sameItem.windowID) now at x=\(Int(sameItem.frame.minX)) (was \(originalX))\n".utf8
                ))
            } else {
                FileHandle.standardError.write(Data("[MoveTest] after: victim disappeared\n".utf8))
            }
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
