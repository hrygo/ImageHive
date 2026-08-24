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
