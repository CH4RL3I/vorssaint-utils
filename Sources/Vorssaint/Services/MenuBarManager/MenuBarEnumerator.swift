// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint Menu-Bar-Manager Fork (CH4RL3I)
//
// Minimal port of Ice's Bridging.swift + Private.swift + MenuBarItem.swift
// enumeration path. Ice does this in ~1700 LOC across four files with a
// full item-cache and observer plumbing; here we compress the actual
// enumeration to what a first prototype needs: list all menu-bar-item
// windows and expose their metadata.
//
// Uses private CGSGetProcessMenuBarWindowList (declared via @_silgen_name)
// paired with the public CGWindowListCopyWindowInfo. No AXSwift dependency,
// no swizzling.

import CoreGraphics
import Foundation

// MARK: - Private CGS API declarations
// Symbol names copied from Ice/Bridging/Shims/Private.swift. These are
// private macOS APIs; Apple can rename or remove them, but they have been
// stable through macOS 10.x → 26.x and are what Bartender/Ice both use.

typealias VMBCGSConnectionID = Int32

@_silgen_name("CGSMainConnectionID")
private func VMB_CGSMainConnectionID() -> VMBCGSConnectionID

@_silgen_name("CGSGetWindowCount")
private func VMB_CGSGetWindowCount(
    _ cid: VMBCGSConnectionID,
    _ targetCID: VMBCGSConnectionID,
    _ count: inout Int32
) -> CGError

@_silgen_name("CGSGetProcessMenuBarWindowList")
private func VMB_CGSGetProcessMenuBarWindowList(
    _ cid: VMBCGSConnectionID,
    _ targetCID: VMBCGSConnectionID,
    _ count: Int32,
    _ list: UnsafeMutablePointer<CGWindowID>,
    _ outCount: inout Int32
) -> CGError

// Try the direct move approach. Ice's move() uses event-injection cmd-drag
// (~500 LOC). If this simpler private call actually moves menu-bar items
// on macOS 26 we skip that whole port; if it doesn't (typical since ~2022),
// we know Ice's approach is unavoidable.
@_silgen_name("CGSMoveWindow")
func VMB_CGSMoveWindow(
    _ cid: VMBCGSConnectionID,
    _ wid: CGWindowID,
    _ point: UnsafePointer<CGPoint>
) -> CGError

/// Experimental: try to move a menu-bar item to an absolute screen point.
/// Returns the CGError code (0 = success). Log-only for now.
public func vmb_tryMoveMenuBarItem(_ wid: CGWindowID, to point: CGPoint) -> Int32 {
    let cid = VMB_CGSMainConnectionID()
    var p = point
    let result = withUnsafePointer(to: &p) { ptr in
        VMB_CGSMoveWindow(cid, wid, ptr)
    }
    return result.rawValue
}

// MARK: - Item model

/// A menu-bar item observed in the system menu bar. What the service will
/// later assign into visible / hidden / alwaysHidden sections.
public struct EnumeratedMenuBarItem: Hashable, Sendable {
    /// The CGWindowID of the item's status-bar window. Stable across pings.
    public let windowID: CGWindowID
    /// PID of the owning process.
    public let ownerPID: pid_t
    /// The owning process's display name (e.g. "Bartender", "Discord").
    /// Best-effort — comes from CGWindowListCopyWindowInfo.
    public let ownerName: String
    /// The status-bar item's own title. Often empty when the app draws a
    /// custom icon; still useful for identifying separators.
    public let title: String
    /// The frame on the screen. Used later to compute order in the menu bar.
    public let frame: CGRect
}

// MARK: - Enumerator

private func stderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

public enum MenuBarEnumerator {

    /// Fetch every menu-bar-item window currently registered with the
    /// system, across all processes.
    ///
    /// - Returns: List sorted left-to-right by x-position. Empty on error.
    public static func snapshot() -> [EnumeratedMenuBarItem] {
        let cid = VMB_CGSMainConnectionID()
        stderr("[Enum] cid=\(cid)")

        // 1. Ask how many windows exist total; over-allocate the id buffer.
        var totalCount: Int32 = 0
        let countResult = VMB_CGSGetWindowCount(cid, 0, &totalCount)
        stderr("[Enum] CGSGetWindowCount → \(countResult.rawValue), totalCount=\(totalCount)")
        guard countResult == .success, totalCount > 0 else { return [] }

        // 2. Fetch the menu-bar subset. Use withUnsafeMutableBufferPointer so
        //    we pass a proper UnsafeMutablePointer, matching the ABI declared
        //    in Ice's Private.swift. Passing `inout [CGWindowID]` looks the
        //    same in source but is a different calling convention and crashes
        //    with SIGBUS at runtime.
        var ids = [CGWindowID](repeating: 0, count: Int(totalCount))
        var realCount: Int32 = 0
        let listResult = ids.withUnsafeMutableBufferPointer { buffer -> CGError in
            guard let base = buffer.baseAddress else { return .failure }
            return VMB_CGSGetProcessMenuBarWindowList(cid, 0, totalCount, base, &realCount)
        }
        stderr("[Enum] CGSGetProcessMenuBarWindowList → \(listResult.rawValue), realCount=\(realCount)")
        guard listResult == .success else { return [] }
        let windowIDs = Array(ids.prefix(Int(realCount)))
        guard !windowIDs.isEmpty else { return [] }

        // 3. Get metadata for every window in the system, then keep only the
        //    ones our menu-bar list returned. CGWindowListCreateDescriptionFromArray
        //    silently drops entries at NSStatusWindowLevel; asking for the
        //    complete list with .optionAll returns them.
        let allOptions = CGWindowListOption([.optionAll, .excludeDesktopElements])
        guard let allWindowsInfoRaw = CGWindowListCopyWindowInfo(allOptions, kCGNullWindowID),
              let allWindowsInfo = allWindowsInfoRaw as? [[String: Any]]
        else {
            stderr("[Enum] CGWindowListCopyWindowInfo returned nil / wrong shape")
            return []
        }
        let wanted = Set(windowIDs)
        let infosArray = allWindowsInfo.filter { info in
            guard let wid = info[kCGWindowNumber as String] as? CGWindowID else { return false }
            return wanted.contains(wid)
        }
        stderr("[Enum] all-windows list has \(allWindowsInfo.count) entries; filtered to \(infosArray.count) menu-bar entries")

        // 4. Map to our own struct. Keys are constant CFStrings; when the dict
        //    is bridged back as [String: Any] the keys arrive as plain String,
        //    so cast them once here.
        let kNumber = kCGWindowNumber as String
        let kOwnerPID = kCGWindowOwnerPID as String
        let kOwnerName = kCGWindowOwnerName as String
        let kName = kCGWindowName as String
        let kBounds = kCGWindowBounds as String
        stderr("[Enum] first info keys sample: \(infosArray.first?.keys.sorted() ?? [])")
        let items: [EnumeratedMenuBarItem] = infosArray.compactMap { info in
            guard
                let windowID = info[kNumber] as? CGWindowID,
                let pid = info[kOwnerPID] as? Int32
            else {
                return nil
            }
            let name = info[kOwnerName] as? String ?? "?"
            let title = info[kName] as? String ?? ""
            let frame = frameFrom(info[kBounds] as? [String: Any]) ?? .zero
            return EnumeratedMenuBarItem(
                windowID: windowID,
                ownerPID: pid,
                ownerName: name,
                title: title,
                frame: frame
            )
        }

        // 5. Sort left-to-right — the natural menu-bar order.
        return items.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// CGWindowBounds is a dict of { X, Y, Width, Height }; unpack.
    private static func frameFrom(_ bounds: [String: Any]?) -> CGRect? {
        guard let bounds else { return nil }
        guard
            let x = bounds["X"] as? CGFloat,
            let y = bounds["Y"] as? CGFloat,
            let w = bounds["Width"] as? CGFloat,
            let h = bounds["Height"] as? CGFloat
        else {
            return nil
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
