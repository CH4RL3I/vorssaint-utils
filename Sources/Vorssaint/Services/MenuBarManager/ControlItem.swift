// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint Menu-Bar-Manager Fork (CH4RL3I)
//
// Minimal port of jordanbaird/Ice's ControlItem (GPL-3.0-or-later).
// Ice's full ControlItem is 754 LOC across 3 files with window-frame tracking,
// hiding animations and appearance-editor hooks. THIS is the strippled Phase 3
// prototype: it only creates a single NSStatusItem, sets a placeholder icon,
// and can be torn down. Enough to prove that our fork's service can put
// something on the actual menu bar.
//
// The remaining Ice features (hiding state, expanded/collapsed length, image
// tinting, event handlers) are TODO for later sessions.

import AppKit
import Combine

@MainActor
public final class MenuBarControlItem {
    /// Kind of a control item — corresponds 1:1 to Ice's Identifier enum but
    /// re-typed to keep the enum self-contained inside our namespace.
    public enum Kind: String {
        case sectionSeparatorHidden       // sits between visible and hidden
        case sectionSeparatorAlwaysHidden // sits between hidden and always-hidden
    }

    public let kind: Kind

    /// The actual menu-bar icon. The system owns the window; we own this
    /// reference so we can remove it on tear-down.
    private var statusItem: NSStatusItem?

    public init(kind: Kind) {
        self.kind = kind
    }

    /// Attach to the system menu bar. Idempotent — calling twice does nothing.
    public func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Placeholder look: a single-char label. Ice uses a custom SVG in
        // ControlItemImage.swift; that ~250 LOC part is not ported yet.
        if let button = item.button {
            switch kind {
            case .sectionSeparatorHidden:        button.title = "◀"
            case .sectionSeparatorAlwaysHidden:  button.title = "◁"
            }
            button.toolTip = "OpenClaw fork menu-bar-manager placeholder (\(kind.rawValue))"
        }
        self.statusItem = item
    }

    /// Detach from the system menu bar.
    public func uninstall() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.statusItem = nil
    }

    deinit {
        // NSStatusItem is released by the system when we drop our reference,
        // but explicit removal is cleaner.
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
    }
}
