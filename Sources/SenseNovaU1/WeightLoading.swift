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

    /// Load a full NEOChatModel from a checkpoint directory (config.json +
    /// model-*.safetensors). `verify: .all` guarantees every parameter was
    /// filled and no checkpoint key went unused.
    public static func load(
        from directory: URL, dtype: DType = .bfloat16
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

        let sanitized = sanitize(weights, dtype: dtype)
        try model.update(parameters: ModuleParameters.unflattened(sanitized), verify: [.all])
        eval(model)
        return model
    }
}
