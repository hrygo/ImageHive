// E2EParityTests.swift — full-model bf16 parity vs capture_t2i.py fixtures
// (t2i_256x256_s4_bf16). Runs on the GPU stream — the shipping configuration.
//
// Ladder: timesteps → prefill (hidden + KV) → step-0 seams (image_embeds,
// backbone hidden, pixel head, v_cond/v_uncond) → 4-step z trajectory →
// final image (PSNR + PNG for the eyeball gate).
//
// bf16-vs-bf16 across backends accumulates rounding differences over 42
// layers; gates here are relative/cosine, calibrated by first runs.

import Foundation
import MLX
import MLXNN
import XCTest

@testable import SenseNovaU1

final class E2EParityTests: XCTestCase {

    // The component suites pin the CPU stream and that leaks; a CLASS-level
    // re-pin did NOT take effect when other suites ran first (measured: 142 s
    // wall + cos 0.9722 = the CPU-stream signature), so pin per-test on the
    // executing thread. e2e runs the SHIPPING configuration: bf16 on the GPU.

    static let fixturesDir: URL = {
        if let env = ProcessInfo.processInfo.environment["SENSENOVA_T2I_FIXTURES"] {
            return URL(fileURLWithPath: env)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("sensenova-u1-oracle/fixtures/t2i_256x256_s4_bf16")
    }()

    func getModel() throws -> NEOChatModel { try SharedTestModel.get() }

    func fx(_ name: String) throws -> MLXArray {
        try NPY.load(Self.fixturesDir.appendingPathComponent("\(name).npy"))
    }

    func ids(_ name: String) throws -> [Int32] {
        let arr = try fx(name).asType(.int32)
        return arr.asArray(Int32.self)
    }

    func stats(_ label: String, _ a: MLXArray, _ ref: MLXArray) -> (rel: Float, cos: Float) {
        let af = a.asType(.float32).reshaped([-1])
        let rf = ref.asType(.float32).reshaped([-1])
        let d = MLX.abs(af - rf).max().item(Float.self)
        let scale = max(MLX.abs(rf).max().item(Float.self), 1e-6)
        let cos = (af * rf).sum().item(Float.self)
            / max((MLX.sqrt((af * af).sum()) * MLX.sqrt((rf * rf).sum())).item(Float.self), 1e-12)
        print("  [e2e] \(label): max|Δ| = \(d) scale = \(scale) rel = \(d / scale) cos = \(cos)")
        return (d / scale, cos)
    }

    func testTimestepSchedule() throws {
        try Device.withDefaultDevice(Device.gpu) {
        let cfg = try NEOChatConfig.load(from: ComponentParityTests.weightsDir)
        let model = NEOChatModel(cfg)  // schedule is weight-free
        let ts = model.shiftedTimesteps(numSteps: 4, shift: 3.0, enable: true)
        let ref = try fx("timesteps_shifted").asArray(Float.self)
        for (a, b) in zip(ts, ref) {
            XCTAssertEqual(a, b, accuracy: 1e-6)
        }
        }
    }


    func testPrefillParity() throws {
        try Device.withDefaultDevice(Device.gpu) {
        let model = try getModel()
        let condIds = try ids("prefix_cond_input_ids")

        // mirror prefillText but keep the hidden state for comparison
        let s = condIds.count
        let t = MLXArray(condIds.indices.map { Int32($0) })
        let zeros = MLXArray([Int32](repeating: 0, count: s))
        let indexes = THWIndexes(t: t, h: zeros, w: zeros)
        let mask = createBlockCausalMask(tIndexes: t)
        let embeds = model.languageModel.model.embedTokens(MLXArray(condIds).reshaped([1, s]))
        let (hidden, kv) = model.languageModel.model(
            embeds: embeds, stream: .und, indexes: indexes, mask: mask, collectKV: true)
        eval(hidden)

        let (relH, cosH) = stats("prefill hidden", hidden, try fx("prefix_cond_last_hidden"))
        XCTAssertGreaterThan(cosH, 0.999, "prefill hidden cosine")
        _ = relH

        for li in [0, 21, 41] {
            let (_, cK) = stats("prefill k l\(li)", kv[li].keys, try fx("prefix_cond_k_l\(li)"))
            let (_, cV) = stats("prefill v l\(li)", kv[li].values, try fx("prefix_cond_v_l\(li)"))
            XCTAssertGreaterThan(cK, 0.999, "k l\(li)")
            XCTAssertGreaterThan(cV, 0.999, "v l\(li)")
        }
        }
    }


    func testStepZeroParity() throws {
        try Device.withDefaultDevice(Device.gpu) {
        let model = try getModel()
        let condIds = try ids("prefix_cond_input_ids")
        let uncondIds = try ids("prefix_uncond_input_ids")
        let noise = try fx("noise_scaled").asType(.bfloat16)
        let (w, h) = (256, 256)
        let cfg = model.config
        let px = cfg.pixelsPerToken
        let (tokenH, tokenW) = (h / px, w / px)
        let (gridH, gridW) = (h / cfg.patchSize, w / cfg.patchSize)
        let l = tokenH * tokenW

        let prefixCond = model.prefillText(condIds)
        let prefixUncond = model.prefillText(uncondIds)

        // step-0 image embeds
        let z = model.patchify(noise, patchSize: px)
        _ = stats("z0", z, try fx("s0_cond_z_in"))
        let imageInput = model.patchifyChannelFirst(noise, patchSize: cfg.patchSize)
            .reshaped([-1, 3 * cfg.patchSize * cfg.patchSize])
        var imageEmbeds = model.fmModules.visionGen(imageInput, gridH: gridH, gridW: gridW)
            .reshaped([1, l, -1])

        let tVal: Float = try fx("s0_t").item(Float.self)
        let tExp = MLXArray([Float](repeating: tVal, count: l))
        var timeEmb = model.fmModules.timestepEmbedder(tExp).reshaped([1, l, -1])
        _ = stats("s0 timestep emb", timeEmb, try fx("s0_timestep_emb"))
        let sigma = model.noiseScale(tokenH: tokenH, tokenW: tokenW)
        let ns = MLXArray([Float](repeating: sigma / cfg.noiseScaleMaxValue, count: l))
        let nsEmb = model.fmModules.noiseScaleEmbedder(ns).reshaped([1, l, -1])
        _ = stats("s0 noise-scale emb", nsEmb, try fx("s0_noise_scale_emb"))
        timeEmb = timeEmb + nsEmb
        imageEmbeds = imageEmbeds + timeEmb.asType(imageEmbeds.dtype)
        let (relIE, cosIE) = stats("s0 image_embeds", imageEmbeds, try fx("s0_cond_image_embeds"))
        XCTAssertGreaterThan(cosIE, 0.999, "image embeds")
        _ = relIE

        // backbone + head + v, cond branch
        let tIdx = MLXArray([Int32](repeating: Int32(condIds.count), count: l))
        let gi = MLXArray(Int32(0) ..< Int32(l))
        let idxCond = THWIndexes(t: tIdx, h: gi.floorDivide(MLXArray(Int32(tokenW))), w: gi % Int32(tokenW))
        let (hidden, _) = model.languageModel.model(
            embeds: imageEmbeds, stream: .gen, indexes: idxCond, mask: nil,
            prefixKV: prefixCond, collectKV: false)
        let (_, cosBH) = stats("s0 backbone hidden", hidden, try fx("s0_cond_backbone_hidden"))
        XCTAssertGreaterThan(cosBH, 0.998, "backbone hidden")  // GPU runs are deterministic (0.99900 measured); 0.9894 was the CPU-stream leak

        let vCond = model.predictV(
            imageEmbeds: imageEmbeds, indexes: idxCond, prefixKV: prefixCond,
            z: z, t: tVal, tokenH: tokenH, tokenW: tokenW, tEps: 0.02)
        let (_, cosVC) = stats("s0 v_cond", vCond, try fx("s0_cond_v"))
        XCTAssertGreaterThan(cosVC, 0.99, "v_cond")

        let uIdx = MLXArray([Int32](repeating: Int32(uncondIds.count), count: l))
        let idxUncond = THWIndexes(t: uIdx, h: idxCond.h, w: idxCond.w)
        let vUncond = model.predictV(
            imageEmbeds: imageEmbeds, indexes: idxUncond, prefixKV: prefixUncond,
            z: z, t: tVal, tokenH: tokenH, tokenW: tokenW, tEps: 0.02)
        let (_, cosVU) = stats("s0 v_uncond", vUncond, try fx("s0_uncond_v"))
        XCTAssertGreaterThan(cosVU, 0.99, "v_uncond")
        }
    }


    func testFourStepImage() throws {
        try Device.withDefaultDevice(Device.gpu) {
        let model = try getModel()
        let condIds = try ids("prefix_cond_input_ids")
        let uncondIds = try ids("prefix_uncond_input_ids")
        let noise = try fx("noise_scaled").asType(.bfloat16)

        var params = T2IParams()
        params.numSteps = 4
        params.cfgScale = 4.0
        params.timestepShift = 3.0
        params.tEps = 0.02

        let t0 = Date()
        let image = try model.t2iGenerate(
            condIds: condIds, uncondIds: uncondIds, width: 256, height: 256,
            params: params, injectedNoise: noise)
        eval(image)
        print("  [e2e] 4-step 256² wall: \(Date().timeIntervalSince(t0))s")

        let (_, cosImg) = stats("final image", image, try fx("final_image"))

        // PSNR in denormalized [0,1] space
        let half = MLXArray(Float(0.5))
        let aRaw = image.asType(.float32)
        let rRaw = try fx("final_image").asType(.float32)
        let a = clip(aRaw * half + half, min: 0, max: 1)
        let r = clip(rRaw * half + half, min: 0, max: 1)
        let mse = ((a - r) * (a - r)).mean().item(Float.self)
        let psnr = 10 * log10(1.0 / max(mse, 1e-12))
        print("  [e2e] final image PSNR = \(psnr) dB, cos = \(cosImg)")

        // write PNG for the eyeball gate
        let outURL = Self.fixturesDir.appendingPathComponent("swift_final_image_raw.npy")
        try? FileManager.default.removeItem(at: outURL)
        try MLX.save(array: image.asType(.float32), url: outURL)
        print("  [e2e] wrote \(outURL.path)")

        // Calibrated 2026-08-23: swift-bf16 vs oracle-bf16 measured cos 0.9862 /
        // 22.6 dB — per-step v cos is 0.999+ and 4 Euler steps + CFG×4 compound
        // cross-backend bf16 rounding into a slightly different (equally valid)
        // trajectory; the load-bearing gates are the per-pass cosines above +
        // the decoded-image eyeball (quantized-generative doctrine).
        XCTAssertGreaterThan(cosImg, 0.98, "final image cosine")  // GPU deterministic: 0.98621 measured twice bit-identically
        XCTAssertGreaterThan(psnr, 22, "final image PSNR (bf16 cross-backend trajectory drift; 22.615 measured)")
        }
    }

}
