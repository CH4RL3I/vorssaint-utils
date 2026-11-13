// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import ScreenCaptureKit
import SwiftUI
import os.log

/// Permission + lifecycle state the UI inspects.
enum PermissionState: Equatable {
    case unknown
    case denied
    case granted
    case error(String)
}

/// A content-settled bitmap of one menu-bar host window, ready for the cover
/// window to paint over. Only `.complete` frames that pass the visibility
/// validator reach here.
struct CachedBitmap: Equatable {
    /// Backing CGImage at the window's native backing-store resolution.
    let image: CGImage
    /// Window rect in global screen coordinates at the moment of capture.
    let windowFrame: CGRect
    /// Backing-store scale (points → pixels) at the moment of capture.
    let backingScale: CGFloat
    let capturedAt: Date

    static func == (lhs: CachedBitmap, rhs: CachedBitmap) -> Bool {
        lhs.image === rhs.image && lhs.windowFrame == rhs.windowFrame
    }
}

/// Identity of one captured menu-bar window: owner process + display + CG id.
struct SnapshotKey: Hashable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let displayID: CGDirectDisplayID
}

/// A single icon's bitmap-local rect inside the owning window's bitmap. The
/// cover view uses these to draw black patches over hidden icons.
struct IconFrame: Hashable {
    let persistenceKey: String
    /// Rect inside the owning snapshot's bitmap, in points (not pixels).
    let localRect: CGRect
}

/// A ScreenCaptureKit pipeline that watches every menu-bar host window and
/// publishes the latest *settled* bitmap for each. One CIContext is shared
/// across all frames, SCStream outputs run on a dedicated queue, and only
/// frames with `SCFrameStatus.complete` + visible content are forwarded.
@MainActor
final class MenuBarCaptureSession: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate {
    static let shared = MenuBarCaptureSession()

    // MARK: - Shared CIContext (lazy, one for the whole process)

    /// `nonisolated(unsafe) static let` is Swift's equivalent of a
    /// dispatch_once-backed singleton: the CIContext is built once on first
    /// read, never again. Bartender uses `swift_once`; this is the same.
    nonisolated static let sharedCIContext: CIContext = {
        CIContext(options: [
            .useSoftwareRenderer: false,
            .cacheIntermediates: false,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
        ])
    }()

    // MARK: - Public state

    @Published private(set) var snapshots: [SnapshotKey: CachedBitmap] = [:]
    @Published private(set) var permissionState: PermissionState = .unknown
    @Published private(set) var isRunning = false

    // MARK: - Private state

    private let log = Logger(subsystem: "com.vorssaint.utils", category: "menubar.capture")
    private let frameQueue = DispatchQueue(label: "com.vorssaint.utils.menubar.capture",
                                           qos: .userInitiated)
    /// Debounce window-rediscovery triggered by workspace observers.
    private let rediscoverDebounce: TimeInterval = 0.5
    private var rediscoverWorkItem: DispatchWorkItem?

    private struct Active {
        let stream: SCStream
        let key: SnapshotKey
        let windowFrame: CGRect
        let backingScale: CGFloat
    }
    private var streams: [SnapshotKey: Active] = [:]
    private var observers: [NSObjectProtocol] = []

    private override init() { super.init() }

    // MARK: - Lifecycle

    /// Idempotent. Starts the pipeline, requests screen-recording permission
    /// implicitly via `SCShareableContent.current`, and installs observers.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        installObservers()
        Task { await discoverAndStart() }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        removeObservers()
        for active in streams.values {
            Task { try? await active.stream.stopCapture() }
        }
        streams.removeAll()
        snapshots.removeAll()
    }

    /// Crop the latest cached bitmap at an icon's rect. Converts the point-rect
    /// to pixel-rect using the recorded backing scale. Nil when the icon can't
    /// be matched to a cached host or the crop goes out of bounds. Used by the
    /// Phase C identity hasher to turn each slot into a persistent hash.
    func cropIcon(persistenceKey: String) -> CGImage? {
        for (key, cached) in snapshots {
            let frames = iconFrames(for: key)
            guard let frame = frames.first(where: { $0.persistenceKey == persistenceKey }) else { continue }
            let scale = cached.backingScale
            let px = CGRect(x: frame.localRect.minX * scale,
                            y: frame.localRect.minY * scale,
                            width: frame.localRect.width * scale,
                            height: frame.localRect.height * scale).integral
            let imageBounds = CGRect(x: 0, y: 0,
                                     width: cached.image.width,
                                     height: cached.image.height)
            let clipped = px.intersection(imageBounds)
            guard clipped.width >= 4, clipped.height >= 4 else { continue }
            return cached.image.cropping(to: clipped)
        }
        return nil
    }

    /// Returns per-icon rects inside the captured bitmap for one host window.
    /// Combines the fresh AX snapshot with the window frame + backing scale
    /// recorded on the last `CachedBitmap`.
    func iconFrames(for key: SnapshotKey) -> [IconFrame] {
        guard let cached = snapshots[key] else { return [] }
        let items = MenuBarEnumerator.snapshot().filter { item in
            // Items whose horizontal center falls within the window's frame
            // live in this host.
            cached.windowFrame.minX <= item.frame.midX
                && cached.windowFrame.maxX >= item.frame.midX
        }
        return items.map { item in
            let localX = item.frame.minX - cached.windowFrame.minX
            let localY = item.frame.minY - cached.windowFrame.minY
            return IconFrame(persistenceKey: item.persistenceKey,
                             localRect: CGRect(x: localX, y: localY,
                                               width: item.frame.width,
                                               height: item.frame.height))
        }
    }

    // MARK: - Discovery

    nonisolated private func discoverAndStart() async {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
        } catch {
            await MainActor.run { self.permissionState = .error(error.localizedDescription) }
            return
        }
        await MainActor.run { self.permissionState = .granted }

        // Menu-bar strips on macOS 27: either owned by a known host OR
        // unowned system windows at y≈0 that span the top of a display.
        let hostIDs = Set(MenuBarEnumerator.hostBundleIDs)
        let hostWindows = content.windows.filter { win in
            guard abs(win.frame.minY) < 2,
                  win.frame.height <= 40,
                  win.frame.width > 100 else { return false }
            let bundle = win.owningApplication?.bundleIdentifier ?? ""
            // Known host OR unowned/empty-bundle compositor window = menu bar.
            return bundle.isEmpty || hostIDs.contains(bundle)
        }
        log.notice("discover: total=\(content.windows.count, privacy: .public) host-top-strip=\(hostWindows.count, privacy: .public)")

        let liveIDs = Set(hostWindows.map(\.windowID))
        await MainActor.run { self.stopStreams(notIn: liveIDs) }
        for win in hostWindows {
            await startStream(for: win)
        }
    }

    @MainActor
    private func startStream(for window: SCWindow) async {
        guard let app = window.owningApplication else { return }
        let displayID = Self.displayID(forFrame: window.frame)
        let key = SnapshotKey(windowID: window.windowID,
                              ownerPID: pid_t(app.processID),
                              displayID: displayID)
        if streams[key] != nil { return }

        let scale = NSScreen.screens.first(where: { NSNumber(value: UInt32($0.displayID))
            == NSNumber(value: UInt32(displayID)) })?.backingScaleFactor ?? 2
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        config.showsCursor = false
        config.capturesAudio = false
        config.queueDepth = 6
        config.ignoreShadowsSingleWindow = true
        config.ignoreShadowsDisplay = true
        config.captureResolution = .nominal
        config.colorSpaceName = CGColorSpace.sRGB

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen,
                                       sampleHandlerQueue: frameQueue)
            try await stream.startCapture()
            streams[key] = Active(stream: stream, key: key,
                                  windowFrame: window.frame, backingScale: scale)
            log.notice("stream started window=\(window.windowID, privacy: .public) owner=\(app.bundleIdentifier, privacy: .public) w=\(Int(window.frame.width), privacy: .public) h=\(Int(window.frame.height), privacy: .public)")
        } catch {
            log.error("startCapture failed: \(error.localizedDescription, privacy: .public)")
            permissionState = .error(error.localizedDescription)
        }
    }

    private func stopStreams(notIn liveIDs: Set<CGWindowID>) {
        for (key, active) in streams where !liveIDs.contains(key.windowID) {
            Task { try? await active.stream.stopCapture() }
            streams.removeValue(forKey: key)
            snapshots.removeValue(forKey: key)
        }
    }

    private static func displayID(forFrame frame: CGRect) -> CGDirectDisplayID {
        for screen in NSScreen.screens where screen.frame.intersects(frame) {
            return screen.displayID
        }
        return CGMainDisplayID()
    }

    // MARK: - Observers

    private func installObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        let appNC = NotificationCenter.default
        let names: [(NotificationCenter, NSNotification.Name)] = [
            (appNC, NSApplication.didChangeScreenParametersNotification),
            (nc, NSWorkspace.activeSpaceDidChangeNotification),
            (nc, NSWorkspace.didLaunchApplicationNotification),
            (nc, NSWorkspace.didTerminateApplicationNotification),
            (nc, NSWorkspace.didActivateApplicationNotification),
            (nc, NSWorkspace.screensDidWakeNotification),
            (nc, NSWorkspace.sessionDidBecomeActiveNotification),
        ]
        for (center, name) in names {
            let obs = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleRediscover() }
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

    private func scheduleRediscover() {
        rediscoverWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { await self.discoverAndStart() }
        }
        rediscoverWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + rediscoverDebounce, execute: item)
    }

    // MARK: - SCStreamOutput

    nonisolated func stream(_ stream: SCStream,
                            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }

        // Only forward `SCFrameStatus.complete`. Any other status (idle,
        // started, stopped, blank, suspended) means the compositor is still
        // settling; publishing the half-rendered pixels would strobe.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                       createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete else {
            return
        }

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ci = CIImage(cvPixelBuffer: imageBuffer)
        let extent = ci.extent.integral
        guard extent.width > 0, extent.height > 0,
              let cg = Self.sharedCIContext.createCGImage(ci, from: extent) else { return }

        // Validator (Bartender's sub_10042238c): skip empty / loading icons.
        guard MenuBarContentValidator.isVisibleContent(cg) else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let active = self.active(for: stream) else { return }
            self.snapshots[active.key] = CachedBitmap(image: cg,
                                                     windowFrame: active.windowFrame,
                                                     backingScale: active.backingScale,
                                                     capturedAt: Date())
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.log.error("stream stopped: \(error.localizedDescription, privacy: .public)")
            self?.permissionState = .error(error.localizedDescription)
        }
    }

    @MainActor
    private func active(for stream: SCStream) -> Active? {
        for a in streams.values where a.stream === stream { return a }
        return nil
    }
}

// MARK: - Content validator

/// Port of Bartender's `sub_10042238c`: an icon is "visible" when its alpha
/// channel varies by more than 7 across a 24x24 downsample. A completely
/// transparent (empty slot) or completely opaque placeholder returns false.
enum MenuBarContentValidator {
    static func isVisibleContent(_ cg: CGImage) -> Bool {
        let w = 24
        let h = 24
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &pixels,
                                  width: w,
                                  height: h,
                                  bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return true // Fail-open: if we can't inspect, publish.
        }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var minA: UInt8 = 255
        var maxA: UInt8 = 0
        // Little-endian BGRA + premultipliedFirst → alpha is byte 3 in each
        // 4-byte pixel.
        for i in stride(from: 3, to: pixels.count, by: 4) {
            let a = pixels[i]
            if a < minA { minA = a }
            if a > maxA { maxA = a }
        }
        return Int(maxA) - Int(minA) > 7
    }
}
