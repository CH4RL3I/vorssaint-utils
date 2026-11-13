// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine
import CoreGraphics
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Chip model combining the live AX enumeration with the persisted section.
struct MenuBarChipItem: Identifiable, Hashable {
    let persistenceKey: String
    let ownerName: String
    let ownerBundleID: String?
    let title: String
    let section: MenuBarSection
    /// Perceptual hash of the icon pixels, when a cropped capture is available.
    /// Nil for chips whose owning host window hasn't produced a frame yet.
    let iconHash: UInt64?
    /// User-chosen name from the identity store, overrides `ownerName` in the
    /// chip label when present.
    let customName: String?

    var id: String { persistenceKey }

    /// Display name order of precedence: user-chosen name → owner app name →
    /// bundle id → AX title.
    var displayName: String {
        if let name = customName, !name.isEmpty { return name }
        if !ownerName.isEmpty { return ownerName }
        if let bundle = ownerBundleID, !bundle.isEmpty { return bundle }
        return title
    }

    var appIcon: NSImage? {
        if let bundle = ownerBundleID,
           let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            return NSWorkspace.shared.icon(forFile: path.path)
        }
        return nil
    }

    /// Chips of system-container slots carry the synthesized `.slotN` suffix.
    /// Only these should offer a rename action — real app-identified chips
    /// already have their proper name from NSWorkspace. If a hash is available
    /// the rename binds to the hash; otherwise it binds to the (less stable)
    /// persistence key so external-display slots stay renameable until Phase B
    /// gains per-display capture coverage.
    var canRename: Bool {
        persistenceKey.contains(".slot")
    }
}

/// The whole Settings pane: three drop zones (Visible / Hidden / Always
/// hidden), a header with the master toggle, and a live hint about how many
/// extras are currently covered.
struct MenuBarLayoutPane: View {
    @ObservedObject private var manager = MenuBarManagerService.shared
    @ObservedObject private var layout = MenuBarLayoutModel.shared
    @ObservedObject private var capture = MenuBarCaptureSession.shared
    @ObservedObject private var cover = MenuBarCoverCoordinator.shared
    @ObservedObject private var identity = MenuBarIdentityStore.shared
    @State private var items: [MenuBarChipItem] = []
    @State private var refresh = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    @State private var enabled = MenuBarManagerService.shared.isEnabled
    @State private var renameTarget: MenuBarChipItem?
    @State private var renameText: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                permissionBanner
                Group {
                    sectionList(title: "Visible", section: .visible)
                    sectionList(title: "Hidden", section: .hidden)
                    sectionList(title: "Always hidden", section: .alwaysHidden)
                }
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.45)
                footer
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            if enabled { capture.start() }
            refreshItems()
        }
        .onDisappear { capture.stop() }
        .onReceive(refresh) { _ in refreshItems() }
        .alert("Rename icon", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } })
        ) {
            TextField("Display name", text: $renameText)
            Button("Save") {
                if let target = renameTarget {
                    if let hash = target.iconHash, hash != 0 {
                        identity.set(renameText, forHash: hash)
                    } else {
                        identity.set(renameText, forPersistenceKey: target.persistenceKey)
                    }
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: {
            Text("The name is remembered by the icon's pixels, so it survives the owning app relaunching.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Menu Bar Manager").font(.title2.bold())
                Spacer()
                Toggle("Enabled", isOn: $enabled)
                    .toggleStyle(.switch)
                    .onChange(of: enabled) { _, new in
                        manager.isEnabled = new
                        if new { capture.start() } else { capture.stop() }
                    }
            }
            Text("Drag the icons between the three zones. The chevron in your menu bar flips the Hidden group; ⌥-click or right-click it to flip the Always-hidden group.")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }

    @ViewBuilder
    private var permissionBanner: some View {
        switch capture.permissionState {
        case .denied:
            label("Screen Recording permission is required.", icon: "exclamationmark.triangle")
        case .error(let msg):
            label("Capture error: \(msg)", icon: "exclamationmark.triangle")
        case .granted, .unknown:
            EmptyView()
        }
    }

    private func label(_ text: String, icon: String) -> some View {
        HStack {
            Image(systemName: icon)
            Text(text)
            Spacer()
        }
        .padding(8)
        .background(Color.yellow.opacity(0.15))
        .cornerRadius(6)
    }

    private func sectionList(title: String, section: MenuBarSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            let chips = items.filter { $0.section == section }
            FlowLayout(spacing: 8) {
                ForEach(chips) { chip in
                    chipView(chip)
                        .draggable(chip.persistenceKey.menuBarDragPayload) {
                            chipView(chip).opacity(0.7)
                        }
                        .contextMenu {
                            if chip.canRename {
                                Button("Rename…") {
                                    renameText = chip.customName ?? ""
                                    renameTarget = chip
                                }
                                if chip.customName != nil {
                                    Button("Reset name") {
                                        if let hash = chip.iconHash, hash != 0 {
                                            identity.set("", forHash: hash)
                                        } else {
                                            identity.set("", forPersistenceKey: chip.persistenceKey)
                                        }
                                    }
                                }
                            }
                        }
                }
                if chips.isEmpty {
                    Text("Drop icons here").foregroundStyle(.tertiary).font(.callout)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            .dropDestination(for: String.self) { payloads, _ in
                var moved = false
                for payload in payloads {
                    guard let key = String.menuBarDragKey(from: payload) else { continue }
                    layout.assign(key, to: section)
                    moved = true
                }
                if moved { manager.applyPhysicalState() }
                return moved
            }
        }
    }

    private func chipView(_ chip: MenuBarChipItem) -> some View {
        HStack(spacing: 6) {
            if let icon = chip.appIcon {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            } else {
                Image(systemName: "app").frame(width: 16, height: 16)
            }
            Text(chip.displayName).lineLimit(1)
            if let bundle = chip.ownerBundleID, bundle != chip.displayName {
                Text(bundle).foregroundStyle(.tertiary).font(.caption)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.gray.opacity(0.2)))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("Covering \(cover.activeOverlayCount) icon(s)")
                .foregroundStyle(.secondary).font(.caption)
            Spacer()
            Text("Captured \(capture.snapshots.count) frame source(s)")
                .foregroundStyle(.secondary).font(.caption)
        }
    }

    private func refreshItems() {
        // One AX walk per refresh — not one per chip. The previous version
        // called `capture.cropIcon` inside the per-item map, and cropIcon
        // itself ran `MenuBarEnumerator.snapshot()` which triggers a full
        // Accessibility traversal of every host process. 11 chips × 2 Hz = 22
        // AX walks/sec. The pane became unusable.
        let enumerated = MenuBarEnumerator.snapshot()
        let cropByKey = Self.buildCropIndex(enumerated: enumerated,
                                            snapshots: capture.snapshots)

        self.items = enumerated.map { item in
            var iconHash: UInt64?
            var customName: String?
            if let crop = cropByKey[item.persistenceKey] {
                let hash = MenuBarIconHasher.dhash(crop)
                if hash != 0 {
                    iconHash = hash
                    customName = identity.name(for: hash)
                }
            }
            // Fallback: when no crop exists (external display not covered by
            // the capture yet) still allow rename by binding to the slot's
            // persistence key. Less stable than a hash, but keeps the chip
            // usable until Phase B gains per-display coverage.
            if customName == nil {
                customName = identity.name(forPersistenceKey: item.persistenceKey)
            }
            return MenuBarChipItem(persistenceKey: item.persistenceKey,
                                   ownerName: item.ownerName,
                                   ownerBundleID: item.ownerBundleID,
                                   title: item.title,
                                   section: layout.section(for: item.persistenceKey),
                                   iconHash: iconHash,
                                   customName: customName)
        }
    }

    /// Walk every cached host-window bitmap once and return a `key → crop`
    /// map built off a single enumeration pass. Keeps refreshItems O(items)
    /// instead of O(items × hosts × AX-walks).
    private static func buildCropIndex(enumerated: [EnumeratedMenuBarItem],
                                       snapshots: [SnapshotKey: CachedBitmap]) -> [String: CGImage] {
        var out: [String: CGImage] = [:]
        for (_, cached) in snapshots {
            let scale = cached.backingScale
            let imageBounds = CGRect(x: 0, y: 0,
                                     width: cached.image.width,
                                     height: cached.image.height)
            for item in enumerated {
                guard cached.windowFrame.minX <= item.frame.midX,
                      cached.windowFrame.maxX >= item.frame.midX else { continue }
                let localX = item.frame.minX - cached.windowFrame.minX
                let localY = item.frame.minY - cached.windowFrame.minY
                let px = CGRect(x: localX * scale, y: localY * scale,
                                width: item.frame.width * scale,
                                height: item.frame.height * scale).integral
                let clipped = px.intersection(imageBounds)
                guard clipped.width >= 4, clipped.height >= 4,
                      let crop = cached.image.cropping(to: clipped) else { continue }
                out[item.persistenceKey] = crop
            }
        }
        return out
    }
}

// MARK: - Drag payload prefix

/// macOS 27 won't accept a custom UTI without an Info.plist declaration, so
/// we tag payloads with a text prefix instead.
private enum MenuBarDragPrefix {
    static let value = "vorssaint-mbr:"
}

extension String {
    /// Build a draggable payload from an identifier.
    var menuBarDragPayload: String { MenuBarDragPrefix.value + self }

    /// Decode an identifier from a draggable payload, else nil.
    static func menuBarDragKey(from payload: String) -> String? {
        guard payload.hasPrefix(MenuBarDragPrefix.value) else { return nil }
        return String(payload.dropFirst(MenuBarDragPrefix.value.count))
    }
}

// MARK: - FlowLayout

/// Tiny flow layout — SwiftUI's HStack won't wrap, and we need the chips to
/// reflow at narrow widths.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var pos = CGPoint.zero
        var rowHeight: CGFloat = 0
        var size = CGSize.zero
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if pos.x + s.width > width, pos.x > 0 {
                pos.x = 0
                pos.y += rowHeight + spacing
                rowHeight = 0
            }
            pos.x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
            size.width = max(size.width, pos.x)
            size.height = max(size.height, pos.y + rowHeight)
        }
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var pos = CGPoint(x: bounds.minX, y: bounds.minY)
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if pos.x + s.width > bounds.maxX, pos.x > bounds.minX {
                pos.x = bounds.minX
                pos.y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: pos, proposal: ProposedViewSize(s))
            pos.x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}
