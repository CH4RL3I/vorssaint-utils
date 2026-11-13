// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os.log

/// One menu bar extra as the manager sees it: the owning app, where the icon
/// sits on screen, which AX identity it carries and the CGWindow it belongs
/// to. Everything else (hide-state, section) is persisted next to the identity.
struct EnumeratedMenuBarItem: Hashable, Identifiable {
    let ownerPID: pid_t
    let ownerBundleID: String?
    let ownerName: String
    let title: String
    /// Global screen coordinates (origin at the primary display's top-left).
    let frame: CGRect
    /// `kAXIdentifierAttribute` — the autosave name the extra chose for itself
    /// (e.g. `com.apple.CoreLocationAgent.statusItem`). Not every CC-hosted
    /// item exposes one; nil then.
    let axIdentifier: String?
    /// `CGWindowID` the icon is painted into, resolved via CGWindowList by
    /// matching the extra's owner PID + the frame-center X. Zero when no
    /// matching CG window is found.
    let windowID: CGWindowID

    /// Stable persistence identity: AX identifier when available, else
    /// bundle ID + title (which is still unique within a run).
    var persistenceKey: String {
        if let ident = axIdentifier, !ident.isEmpty { return ident }
        if let bundle = ownerBundleID, !bundle.isEmpty { return "\(bundle)::\(title)" }
        return "\(ownerName)::\(title)"
    }

    var id: String { "\(ownerPID).\(persistenceKey).\(Int(frame.minX))" }
}

enum MenuBarEnumerator {
    private static let log = Logger(subsystem: "com.vorssaint.utils",
                                    category: "menubar.enumerator")

    /// Bundle ids whose children own the menu bar extras on modern macOS.
    static let hostBundleIDs: [String] = [
        "com.apple.controlcenter",
        "com.apple.systemuiserver",
        "com.apple.MenuBarAgent",
    ]

    /// Walk the Accessibility tree of each host process plus every running
    /// app that owns at least one legacy status item. Returns the live set
    /// of menu bar items with resolved CGWindow IDs.
    static func snapshot() -> [EnumeratedMenuBarItem] {
        guard AXIsProcessTrusted() else {
            log.debug("AX not trusted — falling back to CGWindowList snapshot")
            return cgWindowFallbackSnapshot()
        }

        let onscreen = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[CFString: Any]] ?? []
        let owners = extrasOwners()

        var items: [EnumeratedMenuBarItem] = []
        for app in owners {
            items.append(contentsOf: enumerate(app: app, onscreen: onscreen))
        }

        // On macOS 27 MenuBarAgent draws third-party icons and exposes them as
        // anonymous slots, while the owning app still reports the same icon
        // through its own AXExtrasMenuBar. Keep the app's (named) entry.
        let appOwned = items.filter { !($0.axIdentifier?.contains(".slot") ?? false) }
        items.removeAll { slot in
            guard slot.axIdentifier?.contains(".slot") == true else { return false }
            return appOwned.contains { owned in
                owned.ownerPID != slot.ownerPID
                    && owned.frame.minX <= slot.frame.midX
                    && owned.frame.maxX >= slot.frame.midX
                    && abs(owned.frame.midY - slot.frame.midY) < 20
            }
        }

        var seen = Set<String>()
        let deduped = items.filter { item in
            let k = "\(item.persistenceKey)@\(Int(item.frame.minX))"
            return seen.insert(k).inserted
        }
        log.debug("snapshot: raw=\(items.count, privacy: .public) dedup=\(deduped.count, privacy: .public)")
        return deduped
    }

    /// CGWindow fallback used when Accessibility is not trusted. Yields what
    /// the compositor shows at the top of the screen, with no AX identity.
    static func cgWindowFallbackSnapshot() -> [EnumeratedMenuBarItem] {
        let onscreen = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[CFString: Any]] ?? []
        var items: [EnumeratedMenuBarItem] = []
        for info in onscreen {
            guard let bounds = cgRect(from: info[kCGWindowBounds]) else { continue }
            guard bounds.minY <= 1, bounds.height <= 40, bounds.width >= 8 else { continue }
            let pidNum = info[kCGWindowOwnerPID] as? NSNumber
            let pid = pid_t(pidNum?.intValue ?? 0)
            let ownerName = info[kCGWindowOwnerName] as? String ?? "unknown"
            let windowNumber = info[kCGWindowNumber] as? NSNumber
            let windowID = CGWindowID(windowNumber?.uint32Value ?? 0)
            let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            items.append(EnumeratedMenuBarItem(
                ownerPID: pid,
                ownerBundleID: bundleID,
                ownerName: ownerName,
                title: info[kCGWindowName] as? String ?? ownerName,
                frame: bounds,
                axIdentifier: nil,
                windowID: windowID
            ))
        }
        return items
    }

    // MARK: - Owner discovery

    /// PIDs known to expose an AXExtrasMenuBar. Each app is asked once when
    /// first seen and once more 3 s later (status items often appear a moment
    /// after launch); slow responders make a full scan cost hundreds of ms.
    private static var ownerPIDs: Set<pid_t> = []
    private static var askedPIDs: [pid_t: Date] = [:]
    private static var settledPIDs: Set<pid_t> = []

    private static func extrasOwners() -> [NSRunningApplication] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != ownPID && !$0.isTerminated
        }
        let now = Date()
        let alive = Set(running.map(\.processIdentifier))
        ownerPIDs.formIntersection(alive)
        settledPIDs.formIntersection(alive)
        askedPIDs = askedPIDs.filter { alive.contains($0.key) }

        for app in running {
            let pid = app.processIdentifier
            if settledPIDs.contains(pid) { continue }
            if let asked = askedPIDs[pid] {
                guard now.timeIntervalSince(asked) > 3 else { continue }
                settledPIDs.insert(pid)
            } else {
                askedPIDs[pid] = now
            }
            if hasExtrasMenuBar(app) { ownerPIDs.insert(pid) }
        }
        return running.filter { ownerPIDs.contains($0.processIdentifier) }
    }

    private static func hasExtrasMenuBar(_ app: NSRunningApplication) -> Bool {
        if app.bundleIdentifier.map(hostBundleIDs.contains) == true { return true }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.1)
        var raw: CFTypeRef?
        return AXUIElementCopyAttributeValue(ax, "AXExtrasMenuBar" as CFString, &raw) == .success
    }

    /// True when the rect lies in the top 40 points of any active display, or
    /// above it: AX reports extras slid up while a full-screen bar is hidden.
    private static func isInMenuBarStrip(_ frame: CGRect) -> Bool {
        guard frame.height <= 40 else { return false }
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetActiveDisplayList(16, &ids, &count)
        for id in ids.prefix(Int(count)) {
            let b = CGDisplayBounds(id)
            if frame.midX >= b.minX, frame.midX < b.maxX,
               frame.minY >= b.minY - 45, frame.maxY <= b.minY + 40 {
                return true
            }
        }
        return false
    }

    // MARK: - Per-app walk

    private static func enumerate(app: NSRunningApplication,
                                  onscreen: [[CFString: Any]]) -> [EnumeratedMenuBarItem] {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.15)
        var raw: CFTypeRef?
        // Only AXExtrasMenuBar — never the full app menu bar (File/Edit/View).
        // Apps that only export the full menu (Acrobat etc.) are not menu-bar
        // extra owners and would otherwise produce dozens of ghost chips.
        guard AXUIElementCopyAttributeValue(axApp, "AXExtrasMenuBar" as CFString, &raw) == .success,
              let extras = raw else { return [] }
        var childrenRaw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(extras as! AXUIElement,
                                            kAXChildrenAttribute as CFString,
                                            &childrenRaw) == .success,
              let childArray = childrenRaw as? [AXUIElement] else { return [] }

        let hostBundle = app.bundleIdentifier
        let hostIsSystemContainer = hostBundle.map(hostBundleIDs.contains) == true

        var items: [EnumeratedMenuBarItem] = []
        var slotIndex = 0
        for child in childArray {
            defer { slotIndex += 1 }
            guard let frame = axFrame(of: child) else { continue }
            // Skip the clock and other non-icon elements that live outside the
            // top strip of the primary screen.
            guard isInMenuBarStrip(frame) else { continue }
            let title = axString(child, kAXTitleAttribute as CFString) ?? ""
            let axIdent = axString(child, kAXIdentifierAttribute as CFString)

            // For items hosted by ControlCenter/SystemUIServer/MenuBarAgent,
            // the AX identifier encodes the real owner's bundle id (e.g.
            // "com.apple.CoreLocationAgent.statusItem"). Derive the display
            // name from that so the Settings pane shows "CoreLocationAgent"
            // instead of 11× "ControlCenter".
            let realBundle: String?
            let realName: String
            let effectiveIdent: String?
            if hostIsSystemContainer, let ident = axIdent, !ident.isEmpty {
                let base = bundlePrefix(from: ident)
                realBundle = base
                realName = displayName(forBundle: base, fallback: title)
                effectiveIdent = ident
            } else if hostIsSystemContainer {
                // Hosted by MenuBarAgent/CC with no AX identifier at all —
                // synthesize a per-slot id so distinct physical slots don't
                // collapse to the same persistence key. Resolving the real
                // owner here needs image-hash matching against the capture;
                // that's Phase C.
                realBundle = hostBundle
                let hostLabel = app.localizedName ?? hostBundle ?? "Agent"
                realName = "\(hostLabel) #\(slotIndex + 1)"
                effectiveIdent = "\(hostBundle ?? "host").slot\(slotIndex)"
            } else {
                realBundle = hostBundle
                realName = app.localizedName ?? hostBundle ?? "unknown"
                effectiveIdent = axIdent
            }

            let windowID = Self.windowID(forPID: app.processIdentifier,
                                         frame: frame,
                                         onscreen: onscreen)
            items.append(EnumeratedMenuBarItem(
                ownerPID: app.processIdentifier,
                ownerBundleID: realBundle,
                ownerName: realName,
                title: title,
                frame: frame,
                axIdentifier: effectiveIdent,
                windowID: windowID
            ))
        }
        return items
    }

    /// Pull the owner's bundle id out of an AX identifier like
    /// `com.apple.CoreLocationAgent.statusItem` → `com.apple.CoreLocationAgent`.
    /// Strips trailing `.statusItem`, `.item`, `.menuExtra` suffixes.
    private static func bundlePrefix(from axIdent: String) -> String? {
        let stripSuffixes = [".statusItem", ".menuExtra", ".item", ".button"]
        var base = axIdent
        for suffix in stripSuffixes where base.hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
            break
        }
        // Only accept dotted bundle-like identifiers.
        return base.contains(".") ? base : nil
    }

    /// Look up a nice display name for a bundle id. Falls back to the last
    /// path component of the bundle, then to the AX title.
    private static func displayName(forBundle bundle: String?, fallback: String) -> String {
        guard let bundle, !bundle.isEmpty else {
            return fallback.isEmpty ? "unknown" : fallback
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            if let name = (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName {
                return name
            }
            return url.deletingPathExtension().lastPathComponent
        }
        // "com.apple.CoreLocationAgent" → "CoreLocationAgent"
        if let tail = bundle.split(separator: ".").last {
            return String(tail)
        }
        return fallback.isEmpty ? bundle : fallback
    }

    private static func axFrame(of element: AXUIElement) -> CGRect? {
        var posRaw: CFTypeRef?
        var sizeRaw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRaw) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRaw) == .success else {
            return nil
        }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRaw as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRaw as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    private static func axString(_ element: AXUIElement, _ attr: CFString) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &raw) == .success else { return nil }
        return raw as? String
    }

    /// CGWindow lookup for the icon's host window: match owner PID and verify
    /// the frame's horizontal center falls inside the window bounds.
    private static func windowID(forPID pid: pid_t,
                                 frame: CGRect,
                                 onscreen: [[CFString: Any]]) -> CGWindowID {
        let probeX = frame.midX
        for info in onscreen {
            guard let ownerNum = info[kCGWindowOwnerPID] as? NSNumber,
                  pid_t(ownerNum.intValue) == pid,
                  let bounds = cgRect(from: info[kCGWindowBounds]),
                  bounds.minY <= 1,
                  bounds.minX <= probeX, bounds.maxX >= probeX else { continue }
            if let num = info[kCGWindowNumber] as? NSNumber {
                return CGWindowID(num.uint32Value)
            }
        }
        return 0
    }

    private static func cgRect(from dict: Any?) -> CGRect? {
        guard let d = dict as? [String: Any] else { return nil }
        let x = (d["X"] as? NSNumber)?.doubleValue ?? 0
        let y = (d["Y"] as? NSNumber)?.doubleValue ?? 0
        let w = (d["Width"] as? NSNumber)?.doubleValue ?? 0
        let h = (d["Height"] as? NSNumber)?.doubleValue ?? 0
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
