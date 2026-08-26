// ArtifactRoundTripTests.swift — the offline-artifact format IS the shipping
// path (every mlx-community repo is one), so save → load must be bit-exact and
// structurally complete. Runs on a tiny synthetic model: no weights, no GPU,
// fast enough for every CI run.
//
// This gate is what catches the format regressions the parity suites can't see:
// a key that sanitize would have mangled, a dropped tensor, a shard-index
// mismatch, or an unevaluated (all-zeros) serialization.

import Foundation
import MLX
import MLXNN
import XCTest

@testable import SenseNovaU1

final class ArtifactRoundTripTests: XCTestCase {

    /// A miniature NEOChat config — same module topology, tiny dimensions.
    static func tinyConfigJSON() -> [String: Any] {
        [
            "downsample_ratio": 0.5,
            "patch_size": 4,
            "noise_scale": 1.0,
            "noise_scale_base_image_seq_len": 64,
            "noise_scale_max_value": 16.0,
            "add_noise_scale_embedding": true,
            "use_pixel_head": true,
            "llm_config": [
                "hidden_size": 128, "intermediate_size": 64, "num_hidden_layers": 1,
                "num_attention_heads": 4, "num_key_value_heads": 2, "head_dim": 16,
                "rms_norm_eps": 1e-6, "vocab_size": 64, "rope_theta": 5_000_000.0,
                "rope_theta_hw": 10000.0, "attention_bias": false,
                "tie_word_embeddings": false,
            ],
            "vision_config": [
                "hidden_size": 32, "llm_hidden_size": 128, "patch_size": 4,
                "downsample_ratio": 0.5, "num_channels": 3,
                "rope_theta_vision": 10000.0, "max_position_embeddings_vision": 10000,
            ],
        ]
    }

    func makeSource(_ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: Self.tinyConfigJSON())
            .write(to: dir.appendingPathComponent("config.json"))
    }

    func testSaveLoadRoundTripIsExact() throws {
        try Device.withDefaultDevice(Device.cpu) {
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("sn-artifact-\(UUID().uuidString)")
            let source = tmp.appendingPathComponent("source")
            let artifact = tmp.appendingPathComponent("artifact")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try makeSource(source)

            let config = try NEOChatConfig.load(from: source)
            let model = NEOChatModel(config)
            eval(model)
            let before = model.parameters().flattened()

            try WeightLoading.saveArtifact(model: model, to: artifact, sourceDir: source)

            // the marker must make the artifact self-identifying — this is what
            // routes loaders away from sanitize()
            XCTAssertTrue(WeightLoading.isArtifact(artifact), "artifact not self-identifying")
            XCTAssertFalse(WeightLoading.isArtifact(source), "source misdetected as artifact")

            let reloaded = try WeightLoading.loadArtifact(from: artifact)
            let after = Dictionary(uniqueKeysWithValues: reloaded.parameters().flattened())

            XCTAssertEqual(before.count, after.count, "tensor count changed across the round trip")
            for (key, value) in before {
                guard let round = after[key] else {
                    XCTFail("missing key after round trip: \(key)")
                    continue
                }
                XCTAssertEqual(round.shape, value.shape, "\(key) shape")
                XCTAssertEqual(round.dtype, value.dtype, "\(key) dtype")
                let d = MLX.abs(round.asType(.float32) - value.asType(.float32)).max().item(Float.self)
                XCTAssertEqual(d, 0, "\(key) is not bit-exact (Δ \(d))")
                // an unevaluated save writes zeros with no error — prove the
                // bytes are real for anything that isn't a zero-initialized norm
                if MLX.abs(value.asType(.float32)).max().item(Float.self) > 0 {
                    XCTAssertGreaterThan(
                        MLX.abs(round.asType(.float32)).max().item(Float.self), 0,
                        "\(key) round-tripped to all zeros (lazy tensor serialized?)")
                }
            }

            // the shard index must name every tensor and only real files
            let indexData = try Data(
                contentsOf: artifact.appendingPathComponent("model.safetensors.index.json"))
            let index = try JSONSerialization.jsonObject(with: indexData) as! [String: Any]
            let map = index["weight_map"] as! [String: String]
            XCTAssertEqual(Set(map.keys), Set(before.map(\.0)), "index does not cover the tensors")
            for shard in Set(map.values) {
                XCTAssertTrue(
                    FileManager.default.fileExists(
                        atPath: artifact.appendingPathComponent(shard).path),
                    "index names a missing shard: \(shard)")
            }
        }
    }

    /// A quantized artifact must reconstruct its own quantization from config —
    /// the published 8bit/4bit repos rely on this and on nothing else.
    func testQuantizedArtifactSelfDescribes() throws {
        try Device.withDefaultDevice(Device.gpu) {
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("sn-artifact-q-\(UUID().uuidString)")
            let source = tmp.appendingPathComponent("source")
            let artifact = tmp.appendingPathComponent("artifact")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try makeSource(source)

            let model = NEOChatModel(try NEOChatConfig.load(from: source))
            WeightLoading.quantizeStreams(model, bits: 8, groupSize: 64)
            try WeightLoading.saveArtifact(
                model: model, to: artifact, sourceDir: source, quantBits: 8)

            let raw = try JSONSerialization.jsonObject(
                with: Data(contentsOf: artifact.appendingPathComponent("config.json")))
                as! [String: Any]
            let q = raw["quantization"] as? [String: Any]
            XCTAssertEqual((q?["bits"] as? NSNumber)?.intValue, 8, "config lost the quant block")

            // loadArtifact must re-quantize structurally BEFORE the update, or
            // the verified update would reject the packed tensors
            let reloaded = try WeightLoading.loadArtifact(from: artifact)
            let layer = reloaded.languageModel.model.layers[0]
            XCTAssertTrue(
                layer.mlp.downProj is QuantizedLinear,
                "reloaded artifact did not restore quantized linears")
        }
    }
}
