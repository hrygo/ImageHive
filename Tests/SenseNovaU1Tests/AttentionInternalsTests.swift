// AttentionInternalsTests.swift — stage-by-stage differential probe against
// capture_attn_internals.py fixtures. Localizes gen-stream divergence to the
// exact sub-op (proj → norm → rope tables → rope apply → sdpa → o_proj).

import Foundation
import MLX
import MLXFast
import MLXNN
import XCTest

@testable import SenseNovaU1

final class AttentionInternalsTests: XCTestCase {


    func fx(_ name: String) throws -> MLXArray {
        try NPY.load(ComponentParityTests.fixturesDir.appendingPathComponent("\(name).npy"))
    }

    func report(_ label: String, _ a: MLXArray, _ b: MLXArray) -> Float {
        XCTAssertEqual(a.shape, b.shape, "\(label) shape \(a.shape) vs \(b.shape)")
        guard a.shape == b.shape else { return .infinity }
        let d = MLX.abs(a.asType(.float32) - b.asType(.float32)).max().item(Float.self)
        print("  [probe] \(label): max|Δ| = \(d)")
        return d
    }

    func testGenAttentionStages() throws {
        try Device.withDefaultDevice(Device.cpu) {
        let store = try ComponentParityTests.ShardStore(ComponentParityTests.weightsDir)
        let cfg = try NEOChatConfig.load(from: ComponentParityTests.weightsDir)
        let attn = MoTAttention(cfg.llm)
        try attn.update(
            parameters: ModuleParameters.unflattened(
                store.module("language_model.model.layers.0.self_attn")),
            verify: [.all])

        let x = try fx("attn0_gen_x")
        let idx = try fx("attn0_gen_indexes").asType(.int32)
        let (b, s) = (1, 12)
        let hDim = cfg.llm.headDim

        // stage 1: projections
        let q = attn.qProjGen(x).reshaped([b, s, attn.numHeads, hDim])
        _ = report("q_proj", q, try fx("attn0_gen_q_proj"))
        let k = attn.kProjGen(x).reshaped([b, s, attn.numKVHeads, hDim])
        _ = report("k_proj", k, try fx("attn0_gen_k_proj"))
        let v = attn.vProjGen(x).reshaped([b, s, attn.numKVHeads, hDim]).transposed(0, 2, 1, 3)
        _ = report("v", v, try fx("attn0_gen_v"))

        // stage 2: qk-norm halves
        let qParts = q.split(parts: 2, axis: -1)
        let qT = attn.qNormGen(qParts[0]).transposed(0, 2, 1, 3)
        let qHW = attn.qNormHWGen(qParts[1]).transposed(0, 2, 1, 3)
        _ = report("q_t_normed", qT, try fx("attn0_gen_q_t_normed"))
        _ = report("q_hw_normed", qHW, try fx("attn0_gen_q_hw_normed"))

        // stage 3: rope tables (reference shape (1, S, dim); ours (1,1,S,dim))
        let (cosT, sinT) = attn.rotaryT.cosSin(positions: idx[0])
        _ = report("cos_t", cosT.reshaped([1, s, -1]), try fx("attn0_gen_cos_t"))
        _ = report("sin_t", sinT.reshaped([1, s, -1]), try fx("attn0_gen_sin_t"))
        let (cosH, _) = attn.rotaryHW.cosSin(positions: idx[1])
        let (cosW, _) = attn.rotaryHW.cosSin(positions: idx[2])
        _ = report("cos_h", cosH.reshaped([1, s, -1]), try fx("attn0_gen_cos_h"))
        _ = report("cos_w", cosW.reshaped([1, s, -1]), try fx("attn0_gen_cos_w"))

        // stage 4: rope application + concat
        let kParts = k.split(parts: 2, axis: -1)
        let kT = attn.kNormGen(kParts[0]).transposed(0, 2, 1, 3)
        let kHW = attn.kNormHWGen(kParts[1]).transposed(0, 2, 1, 3)
        let qHWp = qHW.split(parts: 2, axis: -1)
        let kHWp = kHW.split(parts: 2, axis: -1)
        let (cosH2, sinH2) = attn.rotaryHW.cosSin(positions: idx[1])
        let (cosW2, sinW2) = attn.rotaryHW.cosSin(positions: idx[2])
        let qFull = concatenated(
            [
                applyRotary(qT, cos: cosT, sin: sinT),
                applyRotary(qHWp[0], cos: cosH2, sin: sinH2),
                applyRotary(qHWp[1], cos: cosW2, sin: sinW2),
            ], axis: -1)
        let kFull = concatenated(
            [
                applyRotary(kT, cos: cosT, sin: sinT),
                applyRotary(kHWp[0], cos: cosH2, sin: sinH2),
                applyRotary(kHWp[1], cos: cosW2, sin: sinW2),
            ], axis: -1)
        _ = report("q_roped", qFull, try fx("attn0_gen_q_roped"))
        _ = report("k_roped", kFull, try fx("attn0_gen_k_roped"))

        // stage 5: sdpa (bidirectional, GQA)
        var attnOut = MLXFast.scaledDotProductAttention(
            queries: qFull, keys: kFull, values: v, scale: attn.scale, mask: nil)
        attnOut = attnOut.transposed(0, 2, 1, 3).reshaped([b, s, -1])
        _ = report("attn_pre_o", attnOut, try fx("attn0_gen_attn_pre_o"))

        // stage 6: output projection
        let out = attn.oProjGen(attnOut)
        let dOut = report("out", out, try fx("attn0_gen_out"))

        // full-module path must agree with the staged path
        let idxs = THWIndexes(t: idx[0], h: idx[1], w: idx[2])
        let (outModule, _) = attn(x, stream: .gen, indexes: idxs, mask: nil, prefixKV: nil)
        _ = report("module == staged", outModule, out)
        XCTAssertLessThanOrEqual(dOut, 1e-3, "final out")
        }
    }


    func testGenDecoderLayerStages() throws {
        try Device.withDefaultDevice(Device.cpu) {
        let store = try ComponentParityTests.ShardStore(ComponentParityTests.weightsDir)
        let cfg = try NEOChatConfig.load(from: ComponentParityTests.weightsDir)
        let layer = MoTDecoderLayer(cfg.llm)
        try layer.update(
            parameters: ModuleParameters.unflattened(
                store.module("language_model.model.layers.0")),
            verify: [.all])

        let x = try fx("attn0_gen_x")
        let idx = try fx("attn0_gen_indexes").asType(.int32)
        let idxs = THWIndexes(t: idx[0], h: idx[1], w: idx[2])

        let postInNorm = layer.inputLayernormGen(x)
        _ = report("post_in_norm", postInNorm, try fx("layer0_gen_post_in_norm"))
        let (attnOut, _) = layer.selfAttn(postInNorm, stream: .gen, indexes: idxs, mask: nil, prefixKV: nil)
        _ = report("attn_out", attnOut, try fx("layer0_gen_attn_out"))
        let h1 = x + attnOut
        _ = report("resid1", h1, try fx("layer0_gen_resid1"))
        let postPostNorm = layer.postAttentionLayernormGen(h1)
        _ = report("post_post_norm", postPostNorm, try fx("layer0_gen_post_post_norm"))
        let mlpOut = layer.mlpGen(postPostNorm)
        _ = report("mlp_out", mlpOut, try fx("layer0_gen_mlp_out"))
        let final = h1 + mlpOut
        let d = report("final", final, try fx("layer0_gen_final"))
        XCTAssertLessThanOrEqual(d / 433951, 1e-5, "layer final (relative)")
        }
    }

}
