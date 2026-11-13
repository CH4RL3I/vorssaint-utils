// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Foundation

/// A single NSStatusItem that acts as the Bartender-style chevron. Left-click
/// flips the hidden group; ⌥-click or right-click flips the always-hidden
/// group. One item, no legacy dividers.
@MainActor
final class MenuBarControlItem {
    var onToggleHidden: (() -> Void)?
    var onToggleAlwaysHidden: (() -> Void)?

    private var statusItem: NSStatusItem?
    private static let autosaveName = "VorssaintMenuBarManagerControl"

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = Self.autosaveName
        item.behavior = []
        if let button = item.button {
            button.image = Self.glyph(for: .showsItems)
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(onClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Vorssaint Menu Bar Manager"
        }
        statusItem = item
    }

    func uninstall() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
    }

    /// Renders the current chevron direction. `.showsItems` points left
    /// (icons currently shown, click to tuck them away). `.hidesItems` points
    /// right (icons tucked, click to reveal).
    func render(chevron: MenuBarChevronState) {
        guard let button = statusItem?.button else { return }
        button.image = Self.glyph(for: chevron)
        button.image?.isTemplate = true
    }

    @objc private func onClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp
        let isOption = event?.modifierFlags.contains(.option) == true
        if isRight || isOption {
            onToggleAlwaysHidden?()
        } else {
            onToggleHidden?()
        }
    }

    private static func glyph(for state: MenuBarChevronState) -> NSImage? {
        // chevron.left.2 = tuck icons away (left-pointing double chevron)
        // chevron.right.2 = currently tucked, click to reveal
        let name: String = (state == .showsItems) ? "chevron.left.2" : "chevron.right.2"
        return NSImage(systemSymbolName: name,
                       accessibilityDescription: "Toggle hidden menu bar items")
    }
}
