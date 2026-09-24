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

    /// Two status items internally. The `glyph` item stays visible and thin;
    /// it hosts the button the user clicks. The `blocker` item only exists
    /// while the state is .hidesItems — it's 10 000 pt wide, has no visible
    /// content, and is registered AFTER the glyph so it sits to the left of
    /// it in the menu bar (macOS orders status items right→left in
    /// registration order). Being to the left of the glyph and being wide,
    /// it pushes every item that is further left than itself off-screen.
    private var glyphItem: NSStatusItem?
    private var blockerItem: NSStatusItem?

    public init(kind: Kind) {
        self.kind = kind
    }

    /// Attach to the system menu bar. Idempotent — calling twice does nothing.
    public func install() {
        guard glyphItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            applyGlyph(to: button)
            button.toolTip = "OpenClaw fork menu-bar-manager (\(kind.rawValue))"
            button.target = self
            button.action = #selector(toggleClicked)
            // Send action on either mouse button — matches Bartender's UX.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        self.glyphItem = item
        applyBlocker()
    }

    /// Detach from the system menu bar.
    public func uninstall() {
        if let item = blockerItem {
            NSStatusBar.system.removeStatusItem(item)
            self.blockerItem = nil
        }
        if let item = glyphItem {
            NSStatusBar.system.removeStatusItem(item)
            self.glyphItem = nil
        }
    }

    /// Flip between showing and hiding neighbours.
    public func toggle() {
        state = (state == .showsItems) ? .hidesItems : .showsItems
        applyBlocker()
        applyGlyph(to: glyphItem?.button)
    }

    /// Set the state explicitly (called by MenuBarManagerService when
    /// hydrating from persisted defaults).
    public func setState(_ newState: HidingState) {
        guard state != newState else { return }
        state = newState
        applyBlocker()
        applyGlyph(to: glyphItem?.button)
    }

    /// Add or remove the invisible wide blocker item depending on state.
    /// The glyph item itself stays a normal thin status item and is never
    /// resized — that's why the user always sees where to click.
    private func applyBlocker() {
        switch state {
        case .showsItems:
            if let item = blockerItem {
                NSStatusBar.system.removeStatusItem(item)
                self.blockerItem = nil
            }
        case .hidesItems:
            if blockerItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: 10_000)
                item.button?.title = ""      // invisible
                item.button?.isEnabled = false
                self.blockerItem = item
            }
        }
        // KNOWN LIMITATION on macOS 26 + multi-screen:
        // Requested length=10 000 is clamped by the system to ~2×primary-
        // screen width, and menu-bar items on a secondary display are
        // rendered independently of items on the primary. Result: this
        // blocker does not visually hide neighbouring icons on such a
        // setup. Ice/Bartender ≥2024 solve this by moving items directly
        // via the private CGSMoveWindow API — see Ice's MenuBarItemManager
        // `move(_:to:)`. Porting that is Phase 7.
        let glyphFrame = glyphItem?.button?.window?.frame ?? .zero
        let blockerFrame = blockerItem?.button?.window?.frame ?? .zero
        let screenWidth = NSScreen.main?.frame.width ?? 0
        FileHandle.standardError.write(Data("""
            [ControlItem \(kind.rawValue)] state=\(state)
              glyph:   x=\(Int(glyphFrame.minX))  w=\(Int(glyphFrame.width))
              blocker: x=\(Int(blockerFrame.minX))  w=\(Int(blockerFrame.width))
              screen: \(Int(screenWidth))

            """.utf8))
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
        if let item = blockerItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        if let item = glyphItem {
            NSStatusBar.system.removeStatusItem(item)
        }
    }
}
