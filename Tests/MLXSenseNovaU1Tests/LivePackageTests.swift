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

    /// Held-out pose fixtures (skeleton PNG + identity JPG). Two of the val
    /// subjects are INVALID as pose fixtures — svilpaite's reference frame is
    /// itself a handstand and its skeleton has no arm joints, mohedano the same
    /// class of defect (AB-R-0196) — so the gate names its subject rather than
    /// globbing the directory.
    static func poseFixtures() throws -> (skeleton: Data, identity: Data) {
        let root = URL(fileURLWithPath:
            ProcessInfo.processInfo.environment["SENSENOVA_POSE_FIXTURES"]
            ?? "/Volumes/Satechi/Development/training-resources/Datasets/PoseLoRADev"
                + "/production-dataset/val")
        let skeleton = root.appendingPathComponent("control_pose/bboyairchair_000000.png")
        let identity = root.appendingPathComponent("control_reference/bboyairchair_000000.jpg")
        guard FileManager.default.fileExists(atPath: skeleton.path),
              FileManager.default.fileExists(atPath: identity.path)
        else {
            throw XCTSkip("pose fixtures not present — set SENSENOVA_POSE_FIXTURES")
        }
        return (try Data(contentsOf: skeleton), try Data(contentsOf: identity))
    }

    /// Live smoke for the pose specialty: a two-reference 768² edit driven the
    /// way the consumer drives it — `IEditRequest(images: [skeleton, identity])`
    /// with `SenseNovaVariant.posePrompt` — through the package API on the
    /// pose-8bit tier. Also renders the SWAPPED slot order, which must not come
    /// back as the same image: identical bytes would mean the second reference
    /// slot is being ignored and the two-image path is a lie.
    func testLivePoseEditTwoReference() async throws {
        try requireLive()
        let (skeletonData, identityData) = try Self.poseFixtures()
        let snapshot = Self.artifactsRoot
            .appendingPathComponent("SenseNova-U1.5-8B-MoT-pose-8bit")
        let package = SenseNovaU1Package(
            configuration: .init(variant: .pose8, snapshotPath: snapshot.path))
        try await package.load()

        let skeleton = Image(format: .png, data: skeletonData, width: 768, height: 768)
        let identity = Image(format: .jpeg, data: identityData, width: 768, height: 768)

        func render(_ images: [Image]) async throws -> Data {
            let response = try await package.run(
                IEditRequest(
                    images: images, prompt: SenseNovaVariant.posePrompt,
                    width: 768, height: 768,
                    steps: SenseNovaVariant.pose8.defaultSteps, seed: 42))
            guard let edit = response as? IEditResponse else {
                throw XCTSkip("wrong response type")
            }
            return edit.image.data
        }

        do {
            let correct = try await render([skeleton, identity])
            let swapped = try await render([identity, skeleton])
            XCTAssertGreaterThan(correct.count, 10_000, "suspiciously small PNG")
            let size = decodePNGSize(correct)
            XCTAssertEqual(size?.0, 768)
            XCTAssertEqual(size?.1, 768)
            XCTAssertNotEqual(
                correct, swapped,
                "the two reference slots are interchangeable — slot 2 is not conditioning")
            let receipts = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Docs/receipts/pose-gates")
            try? FileManager.default.createDirectory(
                at: receipts, withIntermediateDirectories: true)
            try? correct.write(to: receipts.appendingPathComponent("wrapper-pose-correct.png"))
            try? swapped.write(to: receipts.appendingPathComponent("wrapper-pose-swapped.png"))
            print("  [live] pose edit: \(correct.count) vs swapped \(swapped.count) bytes")
        } catch {
            await package.unload()
            throw error
        }
        await package.unload()
    }
}
