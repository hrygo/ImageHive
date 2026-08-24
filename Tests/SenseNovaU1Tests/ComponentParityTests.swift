// ComponentParityTests.swift — fixture-driven parity against the torch oracle.
//
// Fixtures: sensenova-u1-oracle/capture_components.py output (fp32, CPU).
// Env overrides: SENSENOVA_FIXTURES, SENSENOVA_WEIGHTS.
// Gates (fp32, CPU stream): single op < 1e-4, block < 1e-3.
//
// Weight-touching tests page tensors lazily out of the safetensors shards via
// the index.json map — no full-model load.

import Foundation
import MLX
import MLXNN
import XCTest

@testable import SenseNovaU1

final class ComponentParityTests: XCTestCase {

    // MARK: - plumbing

    static let fixturesDir: URL = {
        if let env = ProcessInfo.processInfo.environment["SENSENOVA_FIXTURES"] {
            return URL(fileURLWithPath: env)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("sensenova-u1-oracle/fixtures/components")
    }()

    static let weightsDir: URL = {
        if let env = ProcessInfo.processInfo.environment["SENSENOVA_WEIGHTS"] {
            return URL(fileURLWithPath: env)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("weights/SenseNova-U1.5-8B-MoT")
    }()

    override class func setUp() {
        super.setUp()
        // fp32 parity runs on the CPU stream (GPU fp32 matmul noise masks op bugs)
        Device.setDefault(device: Device.cpu)
    }

    func fx(_ name: String) throws -> MLXArray {
        try NPY.load(Self.fixturesDir.appendingPathComponent("\(name).npy"))
    }

    func maxAbsDiff(_ a: MLXArray, _ b: MLXArray) -> Float {
        MLX.abs(a.asType(.float32) - b.asType(.float32)).max().item(Float.self)
    }

    func assertClose(
        _ a: MLXArray, _ b: MLXArray, atol: Float, _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(a.shape, b.shape, "\(label): shape \(a.shape) vs \(b.shape)", file: file, line: line)
        let d = maxAbsDiff(a, b)
        XCTAssertLessThanOrEqual(d, atol, "\(label): max|Δ| = \(d)", file: file, line: line)
    }

    /// Scale-aware gate: max|Δ| ≤ rtol · max(max|ref|, 1). The gen stream runs
    /// activations up to ~4.3e5 at layer 0 (measured — l0 FFN out), where fp32
    /// reduction noise is O(1e-1) absolute yet O(1e-7) relative; absolute
    /// tolerances are meaningless there.
    func assertCloseRel(
        _ a: MLXArray, _ ref: MLXArray, rtol: Float, _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(a.shape, ref.shape, "\(label): shape \(a.shape) vs \(ref.shape)", file: file, line: line)
        let d = maxAbsDiff(a, ref)
        let scale = max(MLX.abs(ref.asType(.float32)).max().item(Float.self), 1)
        XCTAssertLessThanOrEqual(
            d, rtol * scale, "\(label): max|Δ| = \(d), scale = \(scale), rel = \(d / scale)",
            file: file, line: line)
    }

    // Lazily page named tensors out of the shards.
    final class ShardStore {
        let dir: URL
        var map: [String: String] = [:]
        var shards: [String: [String: MLXArray]] = [:]

        init(_ dir: URL) throws {
            self.dir = dir
            let idx = try Data(contentsOf: dir.appendingPathComponent("model.safetensors.index.json"))
            let obj = try JSONSerialization.jsonObject(with: idx) as! [String: Any]
            map = obj["weight_map"] as! [String: String]
        }

        func tensor(_ name: String) throws -> MLXArray {
            guard let shard = map[name] else { throw SenseNovaError.badWeights("unknown key \(name)") }
            if shards[shard] == nil {
                shards[shard] = try loadArrays(url: dir.appendingPathComponent(shard))
            }
            return shards[shard]![name]!
        }

        /// All checkpoint keys under `prefix`, stripped of it, sanitized, fp32.
        func module(_ prefix: String) throws -> [String: MLXArray] {
            var raw: [String: MLXArray] = [:]
            for key in map.keys where key.hasPrefix(prefix + ".") {
                raw[key] = try tensor(key)
            }
            let sane = WeightLoading.sanitize(raw, dtype: .float32)
            var out: [String: MLXArray] = [:]
            for (k, v) in sane {
                out[String(k.dropFirst(prefix.count + 1))] = v
            }
            return out
        }
    }

    // XCTest runs the methods of one class serially; guarded by that.
    nonisolated(unsafe) static var store: ShardStore!

    func getStore() throws -> ShardStore {
        if Self.store == nil { Self.store = try ShardStore(Self.weightsDir) }
        return Self.store
    }

    var config: NEOChatConfig {
        get throws { try NEOChatConfig.load(from: Self.weightsDir) }
    }

    // MARK: - weight-free tests

    func testRopeTables() throws {
        let cfg = try config
        let rotT = DualAxisRotary(dim: cfg.llm.headDim / 2, theta: cfg.llm.ropeTheta)
        let rotHW = DualAxisRotary(dim: cfg.llm.headDim / 4, theta: cfg.llm.ropeThetaHW)

        assertClose(rotT.invFreq, try fx("rope_inv_freq_t"), atol: 1e-7, "inv_freq t")
        assertClose(rotHW.invFreq, try fx("rope_inv_freq_hw"), atol: 1e-7, "inv_freq hw")

        let pos = MLXArray(Int32(0) ..< 128)
        let (cosT, sinT) = rotT.cosSin(positions: pos)
        let (cosHW, sinHW) = rotHW.cosSin(positions: pos)
        assertClose(cosT.reshaped([1, 128, -1]), try fx("rope_cos_t_128"), atol: 1e-5, "cos t")
        assertClose(sinT.reshaped([1, 128, -1]), try fx("rope_sin_t_128"), atol: 1e-5, "sin t")
        assertClose(cosHW.reshaped([1, 128, -1]), try fx("rope_cos_hw_128"), atol: 1e-5, "cos hw")
        assertClose(sinHW.reshaped([1, 128, -1]), try fx("rope_sin_hw_128"), atol: 1e-5, "sin hw")
    }

    func testBlockCausalMask() throws {
        let tIdx = try fx("block_causal_t_idx").asType(.int32)
        let mask = createBlockCausalMask(tIndexes: tIdx)
        let ref = try fx("block_causal_mask")
        // compare allow/deny structure (−inf vs 0), then exact zeros
        let allowOurs = mask .== MLXArray(Float(0))
        let allowRef = ref .== MLXArray(Float(0))
        XCTAssertTrue((allowOurs .== allowRef).all().item(Bool.self), "mask structure")
    }

    func testPatchifyRoundtrip() throws {
        let cfg = try config
        let model = NEOChatModel(cfg)  // random weights fine — pure reshapes
        let img = try fx("patchify_img")
        assertClose(model.patchify(img, patchSize: 32), try fx("patchify_z32_channellast"), atol: 0, "patchify32")
        assertClose(
            model.patchifyChannelFirst(img, patchSize: 16), try fx("patchify_p16_channelfirst"),
            atol: 0, "patchify16cf")
        assertClose(
            model.unpatchify(model.patchify(img, patchSize: 32), patchSize: 32, height: 64, width: 96),
            img, atol: 0, "roundtrip")
    }

    func testPromptTemplate() throws {
        let data = try Data(contentsOf: Self.fixturesDir.appendingPathComponent("prompts.json"))
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let prompt = obj["prompt"] as! String
        XCTAssertEqual(Conversation.t2iCondPrompt(prompt), obj["cond_text"] as! String, "cond prompt")
        XCTAssertEqual(Conversation.t2iUncondPrompt(), obj["uncond_text"] as! String, "uncond prompt")
        XCTAssertEqual(Conversation.imgStartTokenID, Int32(obj["img_start_token_id"] as! Int), "<img> id")
    }

    // MARK: - weight-backed component tests

    func testTimestepEmbedders() throws {
        let store = try getStore()
        for name in ["timestep_embedder", "noise_scale_embedder"] {
            let mod = TimestepEmbedder(hiddenSize: 4096)
            try mod.update(
                parameters: ModuleParameters.unflattened(store.module("fm_modules.\(name)")),
                verify: [.all])
            let t = try fx("\(name)_t")
            let sinus = TimestepEmbedder.timestepEmbedding(t, dim: 256)
            assertClose(sinus, try fx("\(name)_sinusoid"), atol: 1e-6, "\(name) sinusoid")
            assertClose(mod(t), try fx("\(name)_out"), atol: 1e-3, "\(name) out")
        }
    }

    func testConvDecoder() throws {
        let store = try getStore()
        let mod = ConvDecoder(inputDim: 4096)
        try mod.update(
            parameters: ModuleParameters.unflattened(store.module("fm_modules.fm_head")),
            verify: [.all])
        // fixtures are NCHW; our path is NHWC — transpose at the boundary
        let xNCHW = try fx("conv_decoder_in")
        let x = xNCHW.transposed(0, 2, 3, 1)
        let out = mod(x)
        let refOut = try fx("conv_decoder_out").transposed(0, 2, 3, 1)
        assertClose(out, refOut, atol: 1e-3, "conv_decoder out")

        // stage checks localize pixel-shuffle bugs precisely
        let ps1 = pixelShuffleNHWC(x, 2)
        assertClose(ps1, try fx("conv_decoder_ps1").transposed(0, 2, 3, 1), atol: 0, "ps1")
        let s2 = gelu(mod.conv1(ps1))
        assertClose(s2, try fx("conv_decoder_conv1_gelu").transposed(0, 2, 3, 1), atol: 1e-3, "conv1+gelu")
        let s3 = pixelShuffleNHWC(s2, 2)
        assertClose(s3, try fx("conv_decoder_ps2").transposed(0, 2, 3, 1), atol: 1e-3, "ps2")
        let s4 = mod.conv2(s3)
        assertClose(s4, try fx("conv_decoder_conv2").transposed(0, 2, 3, 1), atol: 1e-3, "conv2")
    }

    func testVisionPatchify() throws {
        let store = try getStore()
        let cfg = try config
        let gridHW = try fx("vision_grid_hw").asType(.int32)
        let (gh, gw) = (gridHW[0, 0].item(Int32.self), gridHW[0, 1].item(Int32.self))

        for (tag, prefix) in [("und", "vision_model"), ("gen", "fm_modules.vision_model_mot_gen")] {
            let mod = NEOVisionModel(cfg.vision)
            try mod.update(
                parameters: ModuleParameters.unflattened(store.module(prefix)),
                verify: [.all])
            let input = try fx("vision_\(tag)_in")
            let out = mod(input, gridH: Int(gh), gridW: Int(gw))
            assertClose(out, try fx("vision_\(tag)_out"), atol: 1e-3, "vision \(tag) out")
        }
    }

    func testDecoderLayers() throws {
        let store = try getStore()
        let cfg = try config

        for li in [0, 21, 41] {
            let layer = MoTDecoderLayer(cfg.llm)
            try layer.update(
                parameters: ModuleParameters.unflattened(
                    store.module("language_model.model.layers.\(li)")),
                verify: [.all])
            let tag = "l\(li)"

            // gen stream, no cache, bidirectional
            let xg = try fx("\(tag)_gen_in")
            let idxG = try fx("\(tag)_gen_indexes").asType(.int32)
            let indexesG = THWIndexes(t: idxG[0], h: idxG[1], w: idxG[2])
            let (outG, _) = layer(xg, stream: .gen, indexes: indexesG, mask: nil, prefixKV: nil)
            assertCloseRel(outG, try fx("\(tag)_gen_out"), rtol: 1e-5, "\(tag) gen")

            // und stream, block-causal mask
            let xu = try fx("\(tag)_und_in")
            let idxU = try fx("\(tag)_und_indexes").asType(.int32)
            let indexesU = THWIndexes(t: idxU[0], h: idxU[1], w: idxU[2])
            let mask = createBlockCausalMask(tIndexes: idxU[0])
            let (outU, _) = layer(xu, stream: .und, indexes: indexesU, mask: mask, prefixKV: nil)
            assertCloseRel(outU, try fx("\(tag)_und_out"), rtol: 1e-5, "\(tag) und")

            // gen stream attending over a cached prefix (denoise shape)
            let pk = try fx("\(tag)_gen_prefix_k")
            let pv = try fx("\(tag)_gen_prefix_v")
            let (outC, _) = layer(xg, stream: .gen, indexes: indexesG, mask: nil, prefixKV: (pk, pv))
            assertCloseRel(outC, try fx("\(tag)_gen_cached_out"), rtol: 1e-5, "\(tag) gen+cache")
        }
    }
}
