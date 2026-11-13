// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine
import CoreGraphics
import Foundation
import ScreenCaptureKit
import os.log

/// Borderless, click-through window sitting exactly over one hidden menu-bar
/// icon. Its content is a horizontal gradient sampled from the menu bar's own
/// pixels on either side of the icon, so it blends into the bar.
final class MenuBarCoverWindow: NSWindow {
    private let fillView = NSView()

    init(frame: NSRect) {
        super.init(contentRect: frame,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle,
                              .fullScreenAuxiliary]
        fillView.wantsLayer = true
        fillView.layer?.contentsGravity = .resize
        fillView.layer?.magnificationFilter = .linear
        fillView.layer?.minificationFilter = .linear
        fillView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        fillView.autoresizingMask = [.width, .height]
        contentView = fillView
        setFrame(frame, display: false)
    }

    private var currentFill: CGImage?

    func setFill(_ image: CGImage?) {
        guard image !== currentFill else { return }
        currentFill = image
        fillView.layer?.contents = image
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Keeps one cover window over every hidden icon on every display's menu bar.
/// AX reports icon positions for the active display only; macOS lays the same
/// icons out from the right edge on every other display, so covers are
/// mirrored there. A 30 Hz tick follows each bar as it slides in and out in
/// full screen, so a covered icon never peeks through mid-animation.
@MainActor
final class MenuBarCoverCoordinator: ObservableObject {
    static let shared = MenuBarCoverCoordinator()

    @Published private(set) var activeOverlayCount = 0

    private struct Placement {
        let frame: CGRect          // CG global, with the bar fully shown
        let display: CGDirectDisplayID
    }

    private let log = Logger(subsystem: "com.vorssaint.utils", category: "menubar.cover")
    private var covers: [String: MenuBarCoverWindow] = [:]
    private var placements: [String: Placement] = [:]
    private var fills: [String: (frame: CGRect, image: CGImage)] = [:]
    private var observers: [NSObjectProtocol] = []
    private var pollTimer: Timer?
    private var slideTimer: Timer?
    private var fillTask: Task<Void, Never>?
    private var lastFillAt = Date.distantPast
    private let fillMaxAge: TimeInterval = 20
    private let bars = MenuBarVisibilityTracker()
    private var offsets: [CGDirectDisplayID: CGFloat?] = [:]
    private var lastSeen: [String: Date] = [:]
    private var mirrorFixes: [String: (source: CGRect, x: CGFloat?, y: CGFloat)] = [:]
    private var locateTask: Task<Void, Never>?
    private var lastNearTop: [CGDirectDisplayID: Date] = [:]
    private var lastHiddenAt: [CGDirectDisplayID: Date] = [:]
    private(set) var isActive = false

    private init() {}

    func start() {
        guard !isActive else { return }
        isActive = true
        installObservers()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in MenuBarCoverCoordinator.shared.reconcile() }
        }
        slideTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            Task { @MainActor in MenuBarCoverCoordinator.shared.followBars() }
        }
        reconcile()
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        pollTimer?.invalidate()
        pollTimer = nil
        slideTimer?.invalidate()
        slideTimer = nil
        fillTask?.cancel()
        fillTask = nil
        removeObservers()
        removeAllCovers()
    }

    func reconcile() {
        guard isActive else { return }
        let hiddenKeys = MenuBarLayoutModel.shared.hiddenPersistenceKeys()
        guard !hiddenKeys.isEmpty else {
            removeAllCovers()
            return
        }
        bars.refresh()

        let items = MenuBarEnumerator.snapshot().filter {
            hiddenKeys.contains($0.persistenceKey) && $0.frame.width > 0 && $0.frame.height > 0
        }

        var next: [String: Placement] = [:]
        var jobs: [MenuBarMirrorLocator.Job] = []
        for raw in items {
            guard let home = bars.display(containing: raw.frame) else { continue }
            // AX reports the icon wherever the bar currently is; store it at
            // its fully shown position so the frame (and its fill) stay stable.
            var normalized = raw.frame
            if raw.frame.minY < home.bounds.minY {
                normalized.origin.y = home.bounds.minY + max(0, (home.barHeight - raw.frame.height) / 2)
            }
            let item = (persistenceKey: raw.persistenceKey, frame: normalized)
            next["\(item.persistenceKey)@\(home.id)"] = Placement(frame: item.frame, display: home.id)
            let rightInset = home.bounds.maxX - item.frame.minX
            for other in bars.displays where other.id != home.id {
                let key = "\(item.persistenceKey)@\(other.id)"
                let h = item.frame.height
                let y = other.bounds.minY + max(0, (other.barHeight - h) / 2)
                let estimate = CGRect(x: other.bounds.maxX - rightInset, y: y,
                                      width: item.frame.width, height: h)
                if let fix = mirrorFixes[key], fix.source == item.frame {
                    guard let x = fix.x else { continue }
                    let found = CGRect(x: x, y: fix.y, width: item.frame.width, height: h)
                    guard other.iconArea.contains(CGPoint(x: found.midX, y: found.midY)) else { continue }
                    next[key] = Placement(frame: found, display: other.id)
                } else {
                    let search = CGRect(x: other.iconArea.minX, y: estimate.minY - 4,
                                        width: other.iconArea.width, height: h + 8)
                    jobs.append(.init(key: key, source: item.frame, estimate: estimate, search: search))
                }
            }
        }
        if !jobs.isEmpty { locateMirrors(jobs) }

        // AX occasionally drops an item for a pass (mid-animation, app busy).
        // Keep its last placement for a few seconds instead of uncovering it.
        let now = Date()
        for key in next.keys { lastSeen[key] = now }
        for (key, placement) in placements where next[key] == nil {
            if let seen = lastSeen[key], now.timeIntervalSince(seen) < 3 {
                next[key] = placement
            }
        }

        for (key, window) in covers where next[key] == nil {
            window.orderOut(nil)
            covers.removeValue(forKey: key)
        }
        placements = next

        for (key, placement) in next where covers[key] == nil {
            covers[key] = MenuBarCoverWindow(frame: Self.cocoaRect(fromCG: placement.frame))
        }
        followBars(force: true)

        // Only bars that are fully shown can be sampled; a missing fill on a
        // slid-away bar must not trigger a resample every pass.
        var needsFill = Date().timeIntervalSince(lastFillAt) > fillMaxAge
        for (key, placement) in next {
            if let fill = fills[key], fill.frame == placement.frame {
                covers[key]?.setFill(fill.image)
            } else if offsets[placement.display] == .some(0) {
                needsFill = true
            }
        }

        if activeOverlayCount != covers.count {
            log.notice("covers=\(self.covers.count, privacy: .public) hiddenKeys=\(hiddenKeys.count, privacy: .public) items=\(items.count, privacy: .public)")
        }
        activeOverlayCount = covers.count

        if needsFill {
            let targets = next.compactMap { key, p -> (String, CGRect)? in
                offsets[p.display] == .some(0) ? (key, p.frame) : nil
            }
            if !targets.isEmpty { refreshFills(targets) }
        }
    }

    /// Moves every cover with its bar's current slide offset and hides covers
    /// whose bar is slid away. A bar only slides in when the pointer reaches
    /// the top of an auto-hiding display, so the window query runs at 30 Hz
    /// just for those displays while the pointer is near the top (and for a
    /// moment after it leaves, to follow the slide-out); otherwise the value
    /// from the once-a-second reconcile is reused.
    private func followBars(force: Bool = false) {
        guard isActive, !covers.isEmpty else { return }
        let now = Date()
        let mouse = NSEvent.mouseLocation
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let mouseCG = CGPoint(x: mouse.x, y: primaryHeight - mouse.y)

        for display in Set(placements.values.map(\.display)) {
            guard let info = bars.displays.first(where: { $0.id == display }) else { continue }
            let nearTop = info.bounds.contains(mouseCG) && mouseCG.y - info.bounds.minY < 80
            if nearTop { lastNearTop[display] = now }
            let recentlyNear = lastNearTop[display].map { now.timeIntervalSince($0) < 1.5 } ?? false
            let autoHides = lastHiddenAt[display].map { now.timeIntervalSince($0) < 600 } ?? false
            let fast = autoHides && recentlyNear
            if force || fast || offsets[display] == nil {
                let value = bars.slideOffset(for: display)
                offsets[display] = .some(value)
                if value == nil { lastHiddenAt[display] = now }
            }
        }

        for (key, window) in covers {
            guard let placement = placements[key],
                  let entry = offsets[placement.display] else { continue }
            guard let dy = entry else {
                if window.isVisible { window.orderOut(nil) }
                continue
            }
            let target = Self.cocoaRect(fromCG: placement.frame.offsetBy(dx: 0, dy: dy))
            if window.frame != target { window.setFrame(target, display: true) }
            if !window.isVisible { window.orderFrontRegardless() }
        }
    }

    /// Both bars must be fully shown, otherwise the screenshot shows app
    /// content instead of icons.
    private func locateMirrors(_ jobs: [MenuBarMirrorLocator.Job]) {
        guard locateTask == nil else { return }
        let ready = jobs.filter { job in
            [job.source, job.estimate].allSatisfy { rect in
                guard let d = bars.display(containing: rect) else { return false }
                return bars.slideOffset(for: d.id) == 0
            }
        }
        guard !ready.isEmpty else { return }
        locateTask = Task { [weak self] in
            let found = await MenuBarMirrorLocator.locate(ready)
            guard let self else { return }
            self.locateTask = nil
            for job in ready {
                let hit = found[job.key] ?? nil
                self.mirrorFixes[job.key] = (job.source, hit?.x, hit?.y ?? job.estimate.minY)
            }
            self.reconcile()
        }
    }

    private func removeAllCovers() {
        for window in covers.values { window.orderOut(nil) }
        covers.removeAll()
        placements.removeAll()
        activeOverlayCount = 0
    }

    private func refreshFills(_ targets: [(String, CGRect)]) {
        guard fillTask == nil else { return }
        lastFillAt = Date()
        fillTask = Task { [weak self] in
            let sampled = await MenuBarBackdropSampler.sample(targets)
            guard let self else { return }
            self.fillTask = nil
            for (key, entry) in sampled {
                self.fills[key] = entry
                self.covers[key]?.setFill(entry.image)
            }
        }
    }

    /// Global CG rect (origin top-left of the primary display, y down) →
    /// Cocoa rect (origin bottom-left of the primary display, y up).
    static func cocoaRect(fromCG rect: CGRect) -> NSRect {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        return NSRect(x: rect.minX,
                      y: primaryHeight - rect.maxY,
                      width: rect.width,
                      height: rect.height)
    }

    // MARK: - Observers

    private func installObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        let appNC = NotificationCenter.default
        let names: [(NotificationCenter, NSNotification.Name)] = [
            (appNC, NSApplication.didChangeScreenParametersNotification),
            (nc, NSWorkspace.activeSpaceDidChangeNotification),
            (nc, NSWorkspace.didActivateApplicationNotification),
        ]
        for (center, name) in names {
            let obs = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    let coordinator = MenuBarCoverCoordinator.shared
                    coordinator.lastFillAt = .distantPast
                    coordinator.reconcile()
                }
            }
            observers.append(obs)
        }
    }

    private func removeObservers() {
        for obs in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            NotificationCenter.default.removeObserver(obs)
        }
        observers.removeAll()
    }
}

/// Finds each display's menu-bar window (WindowServer, layer 24, spanning
/// the display's width) and reports how far it is slid up. On macOS 27 the
/// bar window sits at the display top while shown, moves to y = -height and
/// goes off screen when hidden in full screen, and passes through in between.
@MainActor
final class MenuBarVisibilityTracker {
    struct Display {
        let id: CGDirectDisplayID
        let bounds: CGRect
        var barHeight: CGFloat
        /// Global CG rect where status icons can appear (right of the notch).
        let iconArea: CGRect
    }

    private(set) var displays: [Display] = []
    private var barWindows: [CGDirectDisplayID: [CGWindowID]] = [:]
    private let barLevel = Int(CGWindowLevelForKey(.mainMenuWindow))

    func refresh() {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetActiveDisplayList(16, &ids, &count)
        let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[CFString: Any]] ?? []

        var nextDisplays: [Display] = []
        var nextBars: [CGDirectDisplayID: [CGWindowID]] = [:]
        for id in ids.prefix(Int(count)) {
            let bounds = CGDisplayBounds(id)
            var height: CGFloat = 0
            var windows: [CGWindowID] = []
            for info in all {
                guard (info[kCGWindowLayer] as? Int) == barLevel,
                      (info[kCGWindowOwnerName] as? String) == "Window Server",
                      let b = Self.rect(info[kCGWindowBounds]),
                      abs(b.minX - bounds.minX) < 1, abs(b.width - bounds.width) < 1,
                      b.height <= 40, b.minY <= bounds.minY + 1, b.minY >= bounds.minY - 41,
                      let num = info[kCGWindowNumber] as? NSNumber else { continue }
                windows.append(CGWindowID(num.uint32Value))
                height = max(height, b.height)
            }
            nextBars[id] = windows
            nextDisplays.append(Display(id: id, bounds: bounds, barHeight: height,
                                        iconArea: Self.iconArea(for: id, bounds: bounds)))
        }
        displays = nextDisplays
        barWindows = nextBars
    }

    func display(containing rect: CGRect) -> Display? {
        displays.first { $0.bounds.minX <= rect.midX && rect.midX < $0.bounds.maxX }
    }

    /// 0 when the bar is fully shown, negative while sliding, nil when the bar
    /// is hidden. Displays without a detectable bar window count as shown.
    func slideOffset(for display: CGDirectDisplayID) -> CGFloat? {
        guard let ids = barWindows[display], !ids.isEmpty,
              let top = displays.first(where: { $0.id == display })?.bounds.minY else { return 0 }
        var mutable = ids
        let array: CFArray? = mutable.withUnsafeMutableBufferPointer { buf in
            var pointers: [UnsafeRawPointer?] = (0..<buf.count).map {
                UnsafeRawPointer(bitPattern: UInt(buf[$0]))
            }
            return pointers.withUnsafeMutableBufferPointer {
                CFArrayCreate(nil, $0.baseAddress, $0.count, nil)
            }
        }
        guard let array,
              let infos = CGWindowListCreateDescriptionFromArray(array) as? [[CFString: Any]] else { return 0 }
        var best: CGFloat?
        for info in infos where (info[kCGWindowIsOnscreen] as? Bool) == true {
            guard let b = Self.rect(info[kCGWindowBounds]) else { continue }
            let dy = min(0, b.minY - top)
            best = max(best ?? dy, dy)
        }
        return best
    }

    private static func iconArea(for id: CGDirectDisplayID, bounds: CGRect) -> CGRect {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == id }),
              screen.safeAreaInsets.top > 0,
              let right = screen.auxiliaryTopRightArea else { return bounds }
        return CGRect(x: bounds.minX + right.minX, y: bounds.minY,
                      width: right.width, height: bounds.height)
    }

    private static func rect(_ value: Any?) -> CGRect? {
        guard let dict = value as? NSDictionary else { return nil }
        var r = CGRect.zero
        return CGRectMakeWithDictionaryRepresentation(dict as CFDictionary, &r) ? r : nil
    }
}

/// Finds where an icon sits on another display's menu bar. The icon is
/// screenshotted where AX reports it, then slid across the whole icon area of
/// the other bar (the notch hides different items on each display, so the
/// layouts can differ by hundreds of points); the best zero-mean normalized
/// cross-correlation wins. NCC ignores the dimming macOS applies to icons on
/// the inactive display's bar. Both images are taken at 1 pixel per point so
/// Retina and non-Retina displays compare directly.
enum MenuBarMirrorLocator {
    struct Job {
        let key: String
        let source: CGRect
        let estimate: CGRect
        let search: CGRect
    }

    private static let minScore: Double = 0.6

    static func locate(_ jobs: [Job]) async -> [String: (x: CGFloat, y: CGFloat)?] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true) else { return [:] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let own = content.applications.filter { $0.processID == ownPID }
        var out: [String: (x: CGFloat, y: CGFloat)?] = [:]
        for job in jobs {
            let search = job.search
            guard let template = await gray(job.source, content: content, excluding: own),
                  let strip = await gray(search, content: content, excluding: own) else {
                out[job.key] = .some(nil)
                continue
            }
            if let (dx, dy) = bestMatch(template, in: strip) {
                out[job.key] = (search.minX + CGFloat(dx), search.minY + CGFloat(dy))
            } else {
                out[job.key] = .some(nil)
            }
        }
        return out
    }

    private struct Gray {
        let width: Int
        let height: Int
        let v: [Double]
    }

    private static func gray(_ rect: CGRect, content: SCShareableContent,
                             excluding own: [SCRunningApplication]) async -> Gray? {
        guard let display = content.displays.first(where: {
            $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY))
        }) else { return nil }
        let clipped = rect.intersection(display.frame)
        guard clipped.width >= 4, clipped.height >= 4 else { return nil }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = clipped.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        let w = Int(clipped.width.rounded()), h = Int(clipped.height.rounded())
        config.width = w
        config.height = h
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config) else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Gray(width: w, height: h, v: buf.map(Double.init))
    }

    private static func bestMatch(_ t: Gray, in s: Gray) -> (Int, Int)? {
        guard s.width >= t.width, s.height >= t.height else { return nil }
        let n = Double(t.width * t.height)
        let tMean = t.v.reduce(0, +) / n
        let tz = t.v.map { $0 - tMean }
        let tNorm = sqrt(tz.reduce(0) { $0 + $1 * $1 })
        guard tNorm > 1e-3 * n else { return nil }

        var best = -Double.infinity
        var bestPos = (0, 0)
        for oy in 0...(s.height - t.height) {
            for ox in 0...(s.width - t.width) {
                var sum = 0.0, sumSq = 0.0, cross = 0.0
                for y in 0..<t.height {
                    let sRow = (oy + y) * s.width + ox
                    let tRow = y * t.width
                    for x in 0..<t.width {
                        let sv = s.v[sRow + x]
                        sum += sv
                        sumSq += sv * sv
                        cross += sv * tz[tRow + x]
                    }
                }
                let variance = sumSq - sum * sum / n
                guard variance > 1e-6 else { continue }
                let score = cross / (tNorm * sqrt(variance))
                if score > best {
                    best = score
                    bestPos = (ox, oy)
                }
            }
        }
        return best >= minScore ? bestPos : nil
    }
}

/// One-shot screenshots of the menu bar (excluding Vorssaint's own windows, so
/// the covers never sample themselves). For every pixel row the most common
/// colour just left and just right of the icon is taken as the bar's
/// background. The two colours form a 2-pixel-wide image that, stretched with linear filtering,
/// becomes a seamless horizontal gradient.
enum MenuBarBackdropSampler {
    private static let margin: CGFloat = 48

    static func sample(_ targets: [(String, CGRect)]) async -> [String: (frame: CGRect, image: CGImage)] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true) else { return [:] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let own = content.applications.filter { $0.processID == ownPID }
        var out: [String: (frame: CGRect, image: CGImage)] = [:]

        for display in content.displays {
            let bounds = display.frame
            let mine = targets.filter { bounds.contains(CGPoint(x: $0.1.midX, y: $0.1.midY)) }
            guard !mine.isEmpty else { continue }
            let union = mine.map(\.1).reduce(CGRect.null) { $0.union($1) }
                .insetBy(dx: -margin, dy: 0)
                .intersection(bounds)
            guard !union.isEmpty else { continue }

            let filter = SCContentFilter(display: display, excludingApplications: own,
                                         exceptingWindows: [])
            let scale = CGFloat(filter.pointPixelScale)
            let config = SCStreamConfiguration()
            config.sourceRect = union.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
            config.width = Int((union.width * scale).rounded())
            config.height = Int((union.height * scale).rounded())
            config.showsCursor = false
            guard let shot = try? await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config),
                  let pixels = Pixels(shot) else { continue }

            for (key, rect) in mine {
                let toPx = { (x: CGFloat) in Int(((x - union.minX) * scale).rounded()) }
                let top = Int(((rect.minY - union.minY) * scale).rounded())
                let rows = max(1, Int((rect.height * scale).rounded()))
                let left = toPx(rect.minX - margin)..<toPx(rect.minX)
                let right = toPx(rect.maxX)..<toPx(rect.maxX + margin)
                if let image = pixels.modeGradient(rows: top..<(top + rows), left: left, right: right) {
                    out[key] = (rect, image)
                }
            }
        }
        return out
    }

    private struct Pixels {
        let width: Int
        let height: Int
        let data: [UInt8]

        init?(_ image: CGImage) {
            width = image.width
            height = image.height
            var buf = [UInt8](repeating: 0, count: width * height * 4)
            guard let ctx = CGContext(data: &buf, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            data = buf
        }

        /// Row 0 of `data` is the top of the image (CGContext memory layout).
        /// Per row and side, the most common colour (bucketed to 32 levels per
        /// channel, then averaged within the winning bucket) is the bar's
        /// background: neighbouring icons, pills and text spread over many
        /// colours, the background is one.
        func modeGradient(rows: Range<Int>, left: Range<Int>, right: Range<Int>) -> CGImage? {
            let rows = rows.clamped(to: 0..<height)
            guard !rows.isEmpty else { return nil }
            var out = [UInt8](repeating: 255, count: rows.count * 2 * 4)
            for (i, y) in rows.enumerated() {
                for (col, span) in [left, right].enumerated() {
                    let span = span.clamped(to: 0..<width)
                    guard !span.isEmpty else { continue }
                    var counts: [Int: (n: Int, r: Int, g: Int, b: Int)] = [:]
                    for x in span {
                        let o = (y * width + x) * 4
                        let r = Int(data[o]), g = Int(data[o + 1]), b = Int(data[o + 2])
                        let bucket = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
                        let c = counts[bucket] ?? (0, 0, 0, 0)
                        counts[bucket] = (c.n + 1, c.r + r, c.g + g, c.b + b)
                    }
                    guard let top = counts.values.max(by: { $0.n < $1.n }) else { continue }
                    let o = (i * 2 + col) * 4
                    out[o] = UInt8(top.r / top.n)
                    out[o + 1] = UInt8(top.g / top.n)
                    out[o + 2] = UInt8(top.b / top.n)
                }
            }
            return out.withUnsafeMutableBytes { raw in
                CGContext(data: raw.baseAddress, width: 2, height: rows.count,
                          bitsPerComponent: 8, bytesPerRow: 8,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
            }
        }
    }
}
