// ImageIOTests.swift — orientation + layout sanity for the CoreGraphics
// loading path (the CG bottom-left-origin flip trap): patch 0 of a
// top-red/bottom-blue image must decode as RED.

import Foundation
import MLX
import XCTest

@testable import SenseNovaU1

final class ImageIOTests: XCTestCase {

    func testOrientationAndNormalization() throws {
        try Device.withDefaultDevice(Device.cpu) {
            let url = ComponentParityTests.fixturesDir.appendingPathComponent("orientation_test.png")
            let img = try SenseNovaImageIO.loadEditImage(url: url)

            XCTAssertEqual(img.gridH, 32)
            XCTAssertEqual(img.gridW, 32)

            // patch layout is (c, p, q): first 256 values of a patch = R channel
            let first = img.pixelValues[0]          // top-left patch (768,)
            let last = img.pixelValues[img.pixelValues.dim(0) - 1]
            let rTop = first[0 ..< 256].mean().item(Float.self)
            let bTop = first[512 ..< 768].mean().item(Float.self)
            let rBot = last[0 ..< 256].mean().item(Float.self)
            let bBot = last[512 ..< 768].mean().item(Float.self)

            // red (1,0,0) ImageNet-normalized: R≈+2.25, B≈−1.80; blue inverts
            XCTAssertGreaterThan(rTop, 1.5, "top-left patch must be red (no vertical flip)")
            XCTAssertLessThan(bTop, -1.0, "top-left patch blue channel")
            XCTAssertLessThan(rBot, -1.0, "bottom-right patch red channel")
            XCTAssertGreaterThan(bBot, 1.5, "bottom-right patch must be blue")
        }
    }
}
