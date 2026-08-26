// LivePackageTests.swift — the wrapper's live smoke: load a REAL artifact via
// the package API and run each surface end-to-end (PNG out, decoded + size-
// checked). This is where the silent-failure class surfaces — offline
// conformance never runs a kernel.
//
// Gated: set SENSENOVA_LIVE_PKG=1 and (optionally) SENSENOVA_ARTIFACTS to the
// local artifacts root. Runs the fast8 tier for T2I and bf16 for an edit.

import CoreGraphics
import Foundation
import ImageIO
import MLXToolKit
import XCTest

@testable import MLXSenseNovaU1

final class LivePackageTests: XCTestCase {

    static let artifactsRoot: URL = {
        if let env = ProcessInfo.processInfo.environment["SENSENOVA_ARTIFACTS"] {
            return URL(fileURLWithPath: env)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("weights/artifacts")
    }()

    func requireLive() throws {
        if ProcessInfo.processInfo.environment["SENSENOVA_LIVE_PKG"] != "1" {
            throw XCTSkip("live package smoke gated behind SENSENOVA_LIVE_PKG=1")
        }
    }

    func decodePNGSize(_ data: Data) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return (cg.width, cg.height)
    }

    func testLiveT2IFast8() async throws {
        try requireLive()
        let snapshot = Self.artifactsRoot.appendingPathComponent("SenseNova-U1.5-8B-MoT-8step-8bit")
        let package = SenseNovaU1Package(
            configuration: .init(variant: .fast8, snapshotPath: snapshot.path))
        try await package.load()
        let response: any CapabilityResponse
        do {
            response = try await package.run(
                T2IRequest(prompt: "A lighthouse on a cliff at dusk, warm window light",
                           width: 512, height: 512, seed: 9))
        } catch {
            await package.unload()  // deterministic: the next test loads 33 GB
            throw error
        }
        await package.unload()
        guard let t2i = response as? T2IResponse else { return XCTFail("wrong response type") }
        XCTAssertGreaterThan(t2i.image.data.count, 10_000, "suspiciously small PNG")
        let size = decodePNGSize(t2i.image.data)
        XCTAssertNotNil(size)
        XCTAssertEqual(size?.0, 512)
        XCTAssertEqual(size?.1, 512)
        print("  [live] t2i fast8: \(t2i.image.data.count) bytes PNG @ \(size!)")
    }

    func testLiveEditBF16() async throws {
        try requireLive()
        let snapshot = Self.artifactsRoot.appendingPathComponent("SenseNova-U1.5-8B-MoT-bf16")
        let package = SenseNovaU1Package(
            configuration: .init(variant: .bf16, snapshotPath: snapshot.path))
        try await package.load()
        let inputURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("sensenova-u1-oracle/renders/sn_1024_s20.png")
        let inputData = try Data(contentsOf: inputURL)

        let response: any CapabilityResponse
        do {
            response = try await package.run(
                IEditRequest(
                images: [Image(format: .png, data: inputData, width: 1024, height: 1024)],
                    prompt: "Make the chair emerald green velvet. Preserve everything else.",
                    width: 512, height: 512, steps: 4, seed: 42))
        } catch {
            await package.unload()
            throw error
        }
        await package.unload()
        guard let edit = response as? IEditResponse else { return XCTFail("wrong response type") }
        XCTAssertGreaterThan(edit.image.data.count, 10_000)
        let size = decodePNGSize(edit.image.data)
        XCTAssertEqual(size?.0, 512)
        XCTAssertEqual(size?.1, 512)
        print("  [live] edit bf16: \(edit.image.data.count) bytes PNG @ \(size!)")
        // keep the smoke artifact for the eyeball
        try? edit.image.data.write(
            to: Self.artifactsRoot.appendingPathComponent("live_edit_smoke.png"))
    }
}
