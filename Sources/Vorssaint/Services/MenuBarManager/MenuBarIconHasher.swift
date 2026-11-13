// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics
import Foundation

/// Perceptual hash of a menu-bar icon crop. Produces a 64-bit difference hash
/// (dHash) by downsampling the input to 9×8 luminance and comparing adjacent
/// pixels left-to-right. Robust against small lighting / anti-alias shifts
/// which keeps the identity stable across launches of the owning app.
enum MenuBarIconHasher {

    /// Compute the dHash from an RGBA/BGRA CGImage of any size. Returns 0
    /// when the image can't be rendered to the tiny luminance buffer.
    static func dhash(_ image: CGImage) -> UInt64 {
        let w = 9, h = 8
        var buf = [UInt8](repeating: 0, count: w * h)
        let gray = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &buf,
                                  width: w, height: h,
                                  bitsPerComponent: 8,
                                  bytesPerRow: w,
                                  space: gray,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return 0
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var hash: UInt64 = 0
        var bit = 0
        for y in 0..<h {
            for x in 0..<(w - 1) {
                let left = buf[y * w + x]
                let right = buf[y * w + x + 1]
                if left > right { hash |= (1 << bit) }
                bit += 1
            }
        }
        return hash
    }

    /// Hamming distance between two dHash values — number of bits that differ.
    /// Two icons are "the same" at distance ≤ 6 in practice (Bartender uses a
    /// similar tolerance in its icon store).
    static func hamming(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    /// Hex string form used as a stable UserDefaults key.
    static func hexKey(for hash: UInt64) -> String {
        String(hash, radix: 16, uppercase: false)
    }
}
