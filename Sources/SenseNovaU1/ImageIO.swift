// ImageIO.swift — reference-image preprocessing for the editing path.
//
// Mirrors `load_image_native`: RGB (RGBA over white) → smart_resize to a
// factor-32 grid within [min, max] pixels → ImageNet normalize → flatten 16px
// patches in (c, p, q) order.
//
// ⚠ Documented deviation: the resample kernel. PIL uses BICUBIC here (the
// reference's `Image.resize` default); we use CoreGraphics high-quality
// interpolation. Parity tests bypass this by injecting the oracle's
// preprocessed pixel_values; the production path accepts the kernel delta
// (input preprocessing, upstream of all weights). If it ever matters,
// qwen25vl-mlx-swift ships parity-locked HF-style resampling to borrow.

import CoreGraphics
import Foundation
import ImageIO
import MLX

public enum SenseNovaImageIO {

    public static let imagenetMean: [Float] = [0.485, 0.456, 0.406]
    public static let imagenetStd: [Float] = [0.229, 0.224, 0.225]

    /// Exact port of `smart_resize` (Qwen2.5-VL rounding rules).
    public static func smartResize(
        height: Int, width: Int, factor: Int = 32,
        minPixels: Int = 65536, maxPixels: Int = 4_194_304
    ) -> (height: Int, width: Int) {
        func round_(_ n: Double) -> Int { Int((n / Double(factor)).rounded()) * factor }
        func ceil_(_ n: Double) -> Int { Int((n / Double(factor)).rounded(.up)) * factor }
        func floor_(_ n: Double) -> Int { Int((n / Double(factor)).rounded(.down)) * factor }

        var hBar = max(factor, round_(Double(height)))
        var wBar = max(factor, round_(Double(width)))
        if hBar * wBar > maxPixels {
            let beta = (Double(height * width) / Double(maxPixels)).squareRoot()
            hBar = max(factor, floor_(Double(height) / beta))
            wBar = max(factor, floor_(Double(width) / beta))
        } else if hBar * wBar < minPixels {
            let beta = (Double(minPixels) / Double(height * width)).squareRoot()
            hBar = ceil_(Double(height) * beta)
            wBar = ceil_(Double(width) * beta)
        }
        return (hBar, wBar)
    }

    /// Load an image file → `EditImage` (und-stream reference input).
    public static func loadEditImage(
        url: URL, patchSize: Int = 16,
        minPixels: Int = 512 * 512, maxPixels: Int = 2048 * 2048
    ) throws -> EditImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw SenseNovaError.badConfig("cannot read image at \(url.path)") }

        let (h, w) = smartResize(
            height: cg.height, width: cg.width, factor: 2 * patchSize,
            minPixels: minPixels, maxPixels: maxPixels)

        // draw RGBA over white → RGBA8 buffer at target size
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw SenseNovaError.badConfig("cannot create bitmap context") }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { throw SenseNovaError.badConfig("no bitmap data") }

        // RGBA8 → fp32 CHW normalized
        let pixelCount = w * h
        let bytes = data.bindMemory(to: UInt8.self, capacity: pixelCount * 4)
        var chw = [Float](repeating: 0, count: 3 * pixelCount)
        for c in 0 ..< 3 {
            let mean = imagenetMean[c]
            let std = imagenetStd[c]
            for i in 0 ..< pixelCount {
                chw[c * pixelCount + i] = (Float(bytes[i * 4 + c]) / 255.0 - mean) / std
            }
        }

        let image = MLXArray(chw, [1, 3, h, w])
        // (c, p, q)-ordered 16px patch flatten == patchifyChannelFirst
        let (gh, gw) = (h / patchSize, w / patchSize)
        let flat = image.reshaped([1, 3, gh, patchSize, gw, patchSize])
            .transposed(0, 2, 4, 1, 3, 5)
            .reshaped([gh * gw, 3 * patchSize * patchSize])
        return EditImage(pixelValues: flat, gridH: gh, gridW: gw)
    }
}
