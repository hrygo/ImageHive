// WeightLoading.swift — checkpoint → module tree.
//
// The module hierarchy's @ModuleInfo keys mirror the HF checkpoint names
// segment-for-segment, so loading is: read shards → sanitize → unflatten →
// update(verify: .all). Sanitize owns ALL remapping (never the constructor,
// never first-forward):
//   • torch Conv2d (O, I, kH, kW) → MLX (O, kH, kW, I)
//   • embedder Sequential indices: `mlp.2` → `mlp.1` (SiLU held slot 1)
//   • dtype cast policy: EVERYTHING → bf16 by default (the reference CLI's
//     `--dtype bfloat16` casts the fp32-stored gen stream too); fp32 for parity.

import Foundation
import MLX
import MLXNN

public enum WeightLoading {

    static let convWeightSuffixes = [
        "patch_embedding.weight",
        "dense_embedding.weight",
        "fm_head.conv1.weight",
        "fm_head.conv2.weight",
    ]

    /// Apply all key/layout/dtype transforms to a raw checkpoint dictionary.
    public static func sanitize(
        _ raw: [String: MLXArray], dtype: DType = .bfloat16
    ) -> [String: MLXArray] {
        var out: [String: MLXArray] = [:]
        out.reserveCapacity(raw.count)
        for (rawKey, rawValue) in raw {
            var key = rawKey
            var value = rawValue

            // torch Sequential index for the embedder MLPs: 0, (1=SiLU), 2
            if key.contains("timestep_embedder.mlp.2.") || key.contains("noise_scale_embedder.mlp.2.") {
                key = key.replacingOccurrences(of: ".mlp.2.", with: ".mlp.1.")
            }

            if convWeightSuffixes.contains(where: { key.hasSuffix($0) }) {
                value = value.transposed(0, 2, 3, 1)  // (O,I,kH,kW) → (O,kH,kW,I)
            }

            out[key] = value.asType(dtype)
        }
        return out
    }

    /// Merge a LoRA file (reference `load_and_merge_lora_weight` semantics:
    /// `W += (alpha/rank) · up @ down`, fp32 math, cast back) into a raw
    /// checkpoint-key weight dictionary. The 8-step distill targets only the
    /// 294 gen-stream projections; every `.lora_down` MUST find its base
    /// weight or the LoRA doesn't belong to this checkpoint.
    public static func applyLoRA(
        to weights: inout [String: MLXArray], lora: [String: MLXArray]
    ) throws -> Int {
        var merged = 0
        for (loraKey, down) in lora where loraKey.hasSuffix(".lora_down.weight") {
            let base = String(loraKey.dropLast(".lora_down.weight".count))
            let weightKey = base + ".weight"
            guard let w = weights[weightKey],
                  let up = lora[base + ".lora_up.weight"],
                  let alpha = lora[base + ".alpha"]
            else {
                throw SenseNovaError.badWeights(
                    "LoRA target \(base) has no matching base weight — wrong base checkpoint?")
            }
            let rank = Float(down.dim(0))
            let scale = alpha.asType(.float32).item(Float.self) / rank
            let delta = matmul(up.asType(.float32), down.asType(.float32)) * scale
            weights[weightKey] = (w.asType(.float32) + delta).asType(w.dtype)
            merged += 1
        }
        return merged
    }

    /// Load a full NEOChatModel from a checkpoint directory (config.json +
    /// model-*.safetensors). `verify: .all` guarantees every parameter was
    /// filled and no checkpoint key went unused. `loraURL` merges an adapter
    /// (e.g. the 8-step distill) into the base weights before the dtype cast.
    public static func load(
        from directory: URL, dtype: DType = .bfloat16, loraURL: URL? = nil
    ) throws -> NEOChatModel {
        let config = try NEOChatConfig.load(from: directory)
        let model = NEOChatModel(config)

        var weights: [String: MLXArray] = [:]
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("model-") && $0.pathExtension == "safetensors" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else {
            throw SenseNovaError.badWeights("no model-*.safetensors under \(directory.path)")
        }
        for url in files {
            let part = try loadArrays(url: url)
            weights.merge(part) { _, new in new }
        }

        if let loraURL {
            let lora = try loadArrays(url: loraURL)
            let merged = try applyLoRA(to: &weights, lora: lora)
            let expected = lora.keys.filter { $0.hasSuffix(".lora_down.weight") }.count
            guard merged == expected else {
                throw SenseNovaError.badWeights("LoRA merged \(merged)/\(expected) targets")
            }
        }

        let sanitized = sanitize(weights, dtype: dtype)
        try model.update(parameters: ModuleParameters.unflattened(sanitized), verify: [.all])
        eval(model)
        return model
    }

    // MARK: - Offline artifacts (mlx-community publish format)

    /// Save the model's CURRENT parameter tree as a self-contained artifact:
    /// sharded safetensors in OUR key layout (convs NHWC, embedder mlp.0/mlp.1,
    /// quantized Linears as weight/scales/biases), config.json with the
    /// `sensenova_swift_artifact` marker (+ mlx-convention `quantization` block
    /// when quantized), and the tokenizer/aux files copied from the source
    /// checkpoint. Loading an artifact skips sanitize entirely.
    public static func saveArtifact(
        model: NEOChatModel,
        to outDir: URL,
        sourceDir: URL,
        quantBits: Int? = nil,
        quantGroupSize: Int = 64,
        loraMergedNote: String? = nil,
        shardBytes: Int = 5 << 30
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)

        // MLX is lazy: an unevaluated tensor serializes as ZEROS with no error.
        // load()/quantizeStreams() already eval, but this is the public entry
        // point — materialize unconditionally rather than trusting call order.
        eval(model)
        let flat = model.parameters().flattened().sorted { $0.0 < $1.0 }

        var shards: [[(String, MLXArray)]] = [[]]
        var shardSize = 0
        for (key, value) in flat {
            let bytes = value.nbytes
            if shardSize > 0, shardSize + bytes > shardBytes {
                shards.append([])
                shardSize = 0
            }
            shards[shards.count - 1].append((key, value))
            shardSize += bytes
        }

        var weightMap: [String: String] = [:]
        var total = 0
        for (i, shard) in shards.enumerated() {
            let name = String(
                format: "model-%05d-of-%05d.safetensors", i + 1, shards.count)
            let dict = Dictionary(uniqueKeysWithValues: shard)
            try save(arrays: dict, url: outDir.appendingPathComponent(name))
            for (key, value) in shard {
                weightMap[key] = name
                total += value.nbytes
            }
            print("[artifact] wrote \(name) (\(shard.count) tensors)")
        }
        let index: [String: Any] = [
            "metadata": ["total_size": total], "weight_map": weightMap,
        ]
        try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys])
            .write(to: outDir.appendingPathComponent("model.safetensors.index.json"))

        // config: source + markers
        var config = try JSONSerialization.jsonObject(
            with: Data(contentsOf: sourceDir.appendingPathComponent("config.json"))) as! [String: Any]
        config["sensenova_swift_artifact"] = 1
        if let bits = quantBits {
            config["quantization"] = ["group_size": quantGroupSize, "bits": bits]
        }
        if let note = loraMergedNote { config["lora_merged"] = note }
        try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .prettyPrinted])
            .write(to: outDir.appendingPathComponent("config.json"))

        for aux in ["tokenizer.json", "tokenizer_config.json", "vocab.json", "merges.txt",
                    "added_tokens.json", "special_tokens_map.json"] {
            let src = sourceDir.appendingPathComponent(aux)
            let dst = outDir.appendingPathComponent(aux)
            if fm.fileExists(atPath: src.path) {
                try? fm.removeItem(at: dst)
                try fm.copyItem(at: src, to: dst)
            }
        }
        print("[artifact] done -> \(outDir.path) (\(Double(total) / 1e9) GB)")
    }

    /// True when `directory` holds a Swift artifact (vs the HF checkpoint).
    public static func isArtifact(_ directory: URL) -> Bool {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
              let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return cfg["sensenova_swift_artifact"] != nil
    }

    /// Load an offline artifact: no sanitize, structural quantize when the
    /// config carries a `quantization` block, then a verified update.
    /// Peak ≈ resident (no bf16-materialize-then-quantize transient).
    public static func loadArtifact(from directory: URL) throws -> NEOChatModel {
        let config = try NEOChatConfig.load(from: directory)
        let model = NEOChatModel(config)

        let raw = try JSONSerialization.jsonObject(
            with: Data(contentsOf: directory.appendingPathComponent("config.json"))) as! [String: Any]
        if let q = raw["quantization"] as? [String: Any],
           let bits = (q["bits"] as? NSNumber)?.intValue
        {
            let group = (q["group_size"] as? NSNumber)?.intValue ?? 64
            quantizeStreams(model, bits: bits, groupSize: group)
        }

        var weights: [String: MLXArray] = [:]
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("model-") && $0.pathExtension == "safetensors" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else {
            throw SenseNovaError.badWeights("no artifact shards under \(directory.path)")
        }
        for url in files {
            weights.merge(try loadArrays(url: url)) { _, new in new }
        }
        try model.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
        eval(model)
        return model
    }

    /// Quantize the two transformer streams' Linear weights (group 64).
    /// Precision-sensitive small modules stay high precision: embeddings,
    /// lm_head, every norm, both vision patchifies, the FM embedders, and the
    /// pixel head — together <3% of bytes (the `keep_hi_precision` doctrine).
    /// ⚠ Quantized forwards must run on the GPU stream (Metal-only kernels).
    public static func quantizeStreams(_ model: NEOChatModel, bits: Int, groupSize: Int = 64) {
        quantize(model: model) { path, module in
            guard module is Linear else { return nil }
            guard path.contains("language_model.model.layers.") else { return nil }
            // every layer Linear: q/k/v/o(_mot_gen), mlp(_mot_gen).{gate,up,down}
            return (groupSize: groupSize, bits: bits)
        }
        eval(model)
    }
}
