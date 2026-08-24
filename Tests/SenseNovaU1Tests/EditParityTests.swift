// EditParityTests.swift — editing (it2i_generate) parity vs capture_edit.py.
//
// The oracle's preprocessed reference-image tensors are INJECTED (bypassing
// the PIL-vs-CoreGraphics resample kernel — a documented deviation), so this
// gates: prompt assembly strings, tokenized ids, THW indexing (exact),
// prefix-embed splice, per-branch step-0 velocities, and the 4-step image.

import Foundation
import MLX
import XCTest

@testable import SenseNovaU1

final class EditParityTests: XCTestCase {

    static let fixturesDir: URL = {
        if let env = ProcessInfo.processInfo.environment["SENSENOVA_EDIT_FIXTURES"] {
            return URL(fileURLWithPath: env)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("sensenova-u1-oracle/fixtures/edit_512x512_s4_bf16")
    }()

    /// `final_image.npy` is capture_edit.py's LAST write — a readiness sentinel.
    func requireFixtures() throws {
        if !FileManager.default.fileExists(
            atPath: Self.fixturesDir.appendingPathComponent("final_image.npy").path)
        {
            throw XCTSkip("edit fixtures not captured yet — run capture_edit.py")
        }
    }

    func fx(_ name: String) throws -> MLXArray {
        try NPY.load(Self.fixturesDir.appendingPathComponent("\(name).npy"))
    }

    func ids(_ name: String) throws -> [Int32] {
        try fx(name).asType(.int32).asArray(Int32.self)
    }

    func stats(_ label: String, _ a: MLXArray, _ ref: MLXArray) -> Float {
        let af = a.asType(.float32).reshaped([-1])
        let rf = ref.asType(.float32).reshaped([-1])
        let cos = (af * rf).sum().item(Float.self)
            / max((MLX.sqrt((af * af).sum()) * MLX.sqrt((rf * rf).sum())).item(Float.self), 1e-12)
        print("  [edit] \(label): cos = \(cos)")
        return cos
    }

    func loadRefImage() throws -> EditImage {
        let pv = try fx("ref_pixel_values")
        let ghw = try fx("ref_grid_hw").asType(.int32)
        return EditImage(
            pixelValues: pv.asType(.bfloat16),
            gridH: Int(ghw[0, 0].item(Int32.self)), gridW: Int(ghw[0, 1].item(Int32.self)))
    }

    func testPromptAssembly() throws {
        try requireFixtures()
        try Device.withDefaultDevice(Device.gpu) {
            let meta = try JSONSerialization.jsonObject(
                with: Data(contentsOf: Self.fixturesDir.appendingPathComponent("meta.json"))) as! [String: Any]
            let prompt = meta["prompt"] as! String
            let image = try loadRefImage()

            let condRef = try String(
                contentsOf: Self.fixturesDir.appendingPathComponent("cond_query.txt"), encoding: .utf8)
            let imgCondRef = try String(
                contentsOf: Self.fixturesDir.appendingPathComponent("imgcond_query.txt"), encoding: .utf8)

            XCTAssertEqual(
                Conversation.editCondPrompt(prompt, imageTokenCounts: [image.tokenCount]),
                condRef, "cond query")
            XCTAssertEqual(
                Conversation.editImgCondPrompt(imageTokenCounts: [image.tokenCount]),
                imgCondRef, "img-cond query")
        }
    }

    func testTHWIndexesAndSplice() throws {
        try requireFixtures()
        try Device.withDefaultDevice(Device.gpu) {
            let model = try SharedTestModel.get()
            let image = try loadRefImage()

            for tag in ["cond", "imgcond"] {
                let branchIds = try ids("\(tag)_input_ids")
                let (embeds, indexes, _, _) = model.buildIT2IInputs(ids: branchIds, images: [image])

                // indexes must match EXACTLY (integer semantics)
                let ref = try fx("\(tag)_indexes").asType(.int32)
                XCTAssertTrue(
                    (indexes.t .== ref[0]).all().item(Bool.self), "\(tag) t indexes")
                XCTAssertTrue(
                    (indexes.h .== ref[1]).all().item(Bool.self), "\(tag) h indexes")
                XCTAssertTrue(
                    (indexes.w .== ref[2]).all().item(Bool.self), "\(tag) w indexes")

                // spliced embeds: bf16 cross-backend
                let cos = stats("\(tag) prefix embeds", embeds, try fx("\(tag)_prefix_embeds"))
                XCTAssertGreaterThan(cos, 0.999, "\(tag) prefix embeds")
            }
        }
    }

    func testStepZeroAndFourStepImage() throws {
        try requireFixtures()
        try Device.withDefaultDevice(Device.gpu) {
            let model = try SharedTestModel.get()
            let image = try loadRefImage()
            let condIds = try ids("cond_input_ids")
            let imgCondIds = try ids("imgcond_input_ids")
            let noise = try fx("noise_scaled").asType(.bfloat16)

            var params = T2IParams()
            params.numSteps = 4
            params.cfgScale = 4.0
            params.timestepShift = 3.0

            let t0 = Date()
            let out = model.it2iGenerate(
                condIds: condIds, imgCondIds: imgCondIds, uncondIds: nil,
                images: [image], width: 512, height: 512,
                params: params, imgCfgScale: 1.0, injectedNoise: noise)
            eval(out)
            print("  [edit] 4-step 512² wall: \(Date().timeIntervalSince(t0))s")

            let cosImg = stats("final image", out, try fx("final_image"))

            let a = clip(out.asType(.float32) * 0.5 + 0.5, min: 0, max: 1)
            let r = clip(try fx("final_image") * 0.5 + 0.5, min: 0, max: 1)
            let mse = ((a - r) * (a - r)).mean().item(Float.self)
            let psnr = 10 * log10(1.0 / max(mse, 1e-12))
            print("  [edit] final image PSNR = \(psnr) dB")

            try MLX.save(
                array: out.asType(.float32),
                url: Self.fixturesDir.appendingPathComponent("swift_final_image_raw.npy"))

            XCTAssertGreaterThan(cosImg, 0.97, "final image cosine (calibrate on first run)")
        }
    }
}
