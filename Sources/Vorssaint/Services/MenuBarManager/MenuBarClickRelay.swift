// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import CoreGraphics
import Foundation
import os.log

/// Delivers a synthesised left click to the centre of a menu-bar extra by
/// `CGWindowID`, then restores the pointer and cursor visibility — the exact
/// shape of Bartender's `+[MenuBarHighlightPanel doClickOnWindow:]`:
/// 1. Build the two events via `CGEventCreateMouseEvent`-equivalents.
/// 2. Hide the cursor via `CGDisplayHideCursor`.
/// 3. Dispatch the pair with `CGEventPost` (now the instance `.post(tap:)`).
/// 4. 10 ms later, warp back and `CGDisplayShowCursor`.
enum MenuBarClickRelay {
    private static let log = Logger(subsystem: "com.vorssaint.utils", category: "menubar.click")

    /// Returns true when a click was posted. Returns false when the window has
    /// gone offscreen or has no describable bounds.
    @discardableResult
    static func doClick(windowID: CGWindowID) -> Bool {
        var winID: CGWindowID = windowID
        let windows: CFArray? = withUnsafeMutablePointer(to: &winID) { ptr in
            var values: [UnsafeRawPointer?] = [UnsafeRawPointer(ptr)]
            return values.withUnsafeMutableBufferPointer { buf in
                CFArrayCreate(nil, buf.baseAddress, 1, nil)
            }
        }
        guard let windows,
              let descriptions = CGWindowListCreateDescriptionFromArray(windows)
                as? [[CFString: Any]], let d = descriptions.first else {
            return false
        }

        var bounds = CGRect.zero
        guard let boundsDict = d[kCGWindowBounds] as? [String: Any] as CFDictionary?,
              CGRectMakeWithDictionaryRepresentation(boundsDict, &bounds),
              (d[kCGWindowIsOnscreen] as? Bool) == true else {
            log.debug("Window \(windowID, privacy: .public) not onscreen, skipping click")
            return false
        }

        let target = CGPoint(x: bounds.midX, y: bounds.midY)
        let saved: CGPoint
        if let current = CGEvent(source: nil) {
            saved = current.location
        } else {
            saved = target
        }

        guard let down = CGEvent(mouseEventSource: nil,
                                 mouseType: .leftMouseDown,
                                 mouseCursorPosition: target,
                                 mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil,
                               mouseType: .leftMouseUp,
                               mouseCursorPosition: target,
                               mouseButton: .left) else {
            return false
        }

        CGDisplayHideCursor(CGMainDisplayID())
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) {
            CGWarpMouseCursorPosition(saved)
            CGDisplayShowCursor(CGMainDisplayID())
        }
        return true
    }
}
