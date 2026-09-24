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
public final class MenuBarControlItem: ObservableObject {
    /// Kind of a control item — corresponds 1:1 to Ice's Identifier enum but
    /// re-typed to keep the enum self-contained inside our namespace.
    public enum Kind: String {
        case sectionSeparatorHidden       // sits between visible and hidden
        case sectionSeparatorAlwaysHidden // sits between hidden and always-hidden
    }

    /// The key Bartender/Ice trick: menu-bar items are NOT moved. Instead
    /// the separator's own width is toggled — thin = neighbours visible,
    /// very wide = neighbours are pushed out of the screen edge and hidden.
    public enum HidingState {
        case showsItems  // separator is a thin visible glyph
        case hidesItems  // separator is 10 000 wide, hiding everything right of it
    }

    public let kind: Kind

    @Published public private(set) var state: HidingState = .showsItems

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
        if let button = item.button {
            applyGlyph(to: button)
            button.toolTip = "OpenClaw fork menu-bar-manager (\(kind.rawValue))"
            button.target = self
            button.action = #selector(toggleClicked)
            // Send action on either mouse button — matches Bartender's UX.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        self.statusItem = item
        applyLength()
    }

    /// Detach from the system menu bar.
    public func uninstall() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.statusItem = nil
    }

    /// Flip between showing and hiding neighbours.
    public func toggle() {
        state = (state == .showsItems) ? .hidesItems : .showsItems
        applyLength()
        applyGlyph(to: statusItem?.button)
    }

    /// Set the state explicitly (called by MenuBarManagerService when
    /// hydrating from persisted defaults).
    public func setState(_ newState: HidingState) {
        guard state != newState else { return }
        state = newState
        applyLength()
        applyGlyph(to: statusItem?.button)
    }

    /// Adjust the NSStatusItem's on-screen width based on state.
    private func applyLength() {
        guard let statusItem else { return }
        switch state {
        case .showsItems:
            statusItem.length = NSStatusItem.variableLength
        case .hidesItems:
            // 10 000 pt is Ice's `Lengths.expanded` — wide enough to push
            // every neighbouring item off-screen on any real display size.
            statusItem.length = 10_000
        }
    }

    /// Glyph updates on state changes so the user can see which mode we're in.
    /// When the item is 10 000 pt wide (hidesItems), a plain `title` would be
    /// centered inside those 10 000 pt and disappear off-screen. Fix: draw
    /// the glyph as a right-aligned attributed string so it stays anchored to
    /// the right edge of the button — right where the item actually sits in
    /// the menu bar.
    private func applyGlyph(to button: NSStatusBarButton?) {
        guard let button else { return }
        let glyph: String
        switch (kind, state) {
        case (.sectionSeparatorHidden, .showsItems):        glyph = "◀"
        case (.sectionSeparatorHidden, .hidesItems):        glyph = "▶"
        case (.sectionSeparatorAlwaysHidden, .showsItems):  glyph = "◁"
        case (.sectionSeparatorAlwaysHidden, .hidesItems):  glyph = "▷"
        }
        let para = NSMutableParagraphStyle()
        para.alignment = .right
        button.attributedTitle = NSAttributedString(
            string: glyph,
            attributes: [.paragraphStyle: para]
        )
    }

    @objc private func toggleClicked() {
        toggle()
    }

    deinit {
        // NSStatusItem is released by the system when we drop our reference,
        // but explicit removal is cleaner.
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
    }
}
