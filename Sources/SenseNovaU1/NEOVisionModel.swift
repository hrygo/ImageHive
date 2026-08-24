// NEOVisionModel.swift — mirrors modeling_neo_vit.py.
//
// The "vision model" is a native patchify, not a ViT:
//   16px conv (3→1024, k16 s16) → GELU → 2D RoPE on the EMBEDDINGS →
//   2×2 dense-merge conv (1024→4096, k2 s2) → tokens at 32px granularity.
//
// ⚠ The 2D RoPE here uses the INTERLEAVED pair convention (x[0::2]/x[1::2]) —
// different from the transformer's rotate_half. First 512 dims are rotated by
// the x (COLUMN) index, second 512 by y (ROW). Computed in fp32, cast back.

import Foundation
import MLX
import MLXNN

public final class NEOVisionEmbeddings: Module {
    @ModuleInfo(key: "patch_embedding") var patchEmbedding: Conv2d
    @ModuleInfo(key: "dense_embedding") var denseEmbedding: Conv2d

    let embedDim: Int
    let patchSize: Int
    let downsampleFactor: Int
    // fp32 tables (maxPos, embedDim/4): rows are patch-grid coordinates —
    // grid side ≤ 256 even at 4096px, so 512 rows covers everything the
    // reference's 10000-row cache can ever index in practice.
    // Held in a struct so Module reflection does NOT register them as
    // parameters (bare MLXArray properties would break verify(.all) loads).
    struct RopeTables { let cos: MLXArray; let sin: MLXArray }
    let ropeTables: RopeTables

    public init(_ config: VisionConfig) {
        self.embedDim = config.hiddenSize
        self.patchSize = config.patchSize
        self.downsampleFactor = Int(1.0 / config.downsampleRatio)
        self._patchEmbedding.wrappedValue = Conv2d(
            inputChannels: config.numChannels, outputChannels: config.hiddenSize,
            kernelSize: IntOrPair(config.patchSize), stride: IntOrPair(config.patchSize))
        self._denseEmbedding.wrappedValue = Conv2d(
            inputChannels: config.hiddenSize, outputChannels: config.llmHiddenSize,
            kernelSize: IntOrPair(2), stride: IntOrPair(2))

        // precompute_rope_freqs_sincos(dim=512, base=theta_vision):
        // inv_freq = 1 / theta^(arange(0,512,2)/512) → 256 freqs; outer(pos, inv_freq)
        let ropeDimPart = config.hiddenSize / 2  // 512
        let exponents = MLXArray(stride(from: 0, to: ropeDimPart, by: 2).map { Float($0) / Float(ropeDimPart) })
        let invFreq = 1.0 / MLX.pow(MLXArray(config.ropeThetaVision), exponents)  // (256,)
        let maxPos = 512
        let t = MLXArray(Int32(0) ..< Int32(maxPos)).asType(.float32).reshaped([-1, 1])
        let freqs = t * invFreq.reshaped([1, -1])  // (maxPos, 256)
        self.ropeTables = RopeTables(cos: MLX.cos(freqs), sin: MLX.sin(freqs))
        super.init()
    }

    /// Interleaved 1D rotary on half the embedding: x (N, 512), positions (N,).
    private func applyRotary1D(_ x: MLXArray, positions: MLXArray) -> MLXArray {
        let n = x.dim(0)
        let cos = ropeTables.cos[positions]  // (N, 256)
        let sin = ropeTables.sin[positions]
        let pairs = x.reshaped([n, -1, 2])
        let x1 = pairs[.ellipsis, 0]
        let x2 = pairs[.ellipsis, 1]
        let r1 = x1 * cos - x2 * sin
        let r2 = x1 * sin + x2 * cos
        return stacked([r1, r2], axis: -1).reshaped([n, -1])
    }

    /// pixels: (N, 768) flattened 16px patches in (c, ps, ps) order for ONE
    /// image; grid (gridH, gridW) at 16px granularity. → (gridH/2 · gridW/2, 4096)
    public func callAsFunction(_ pixels: MLXArray, gridH: Int, gridW: Int) -> MLXArray {
        let n = pixels.dim(0)
        precondition(n == gridH * gridW, "pixel patch count != grid")

        // (N, 3, 16, 16) → NHWC → conv16 → (N, 1024)
        let pv = pixels.reshaped([n, 3, patchSize, patchSize]).transposed(0, 2, 3, 1)
        var x = gelu(patchEmbedding(pv)).reshaped([n, embedDim])

        // 2D interleaved RoPE in fp32: first half ← x (column), second ← y (row)
        let idx = MLXArray(Int32(0) ..< Int32(n))
        let absX = idx % Int32(gridW)
        let absY = idx.floorDivide(MLXArray(Int32(gridW)))
        let xf = x.asType(.float32)
        let halves = xf.split(parts: 2, axis: -1)
        let rotated = concatenated(
            [
                applyRotary1D(halves[0], positions: absX),
                applyRotary1D(halves[1], positions: absY),
            ], axis: -1)
        x = rotated.asType(patchEmbedding.weight.dtype)

        // dense 2×2 merge on the (gridH, gridW) map
        let x2d = x.reshaped([1, gridH, gridW, embedDim])
        let merged = denseEmbedding(x2d)  // (1, gridH/2, gridW/2, 4096)
        return merged.reshaped([-1, merged.dim(3)])
    }
}

public final class NEOVisionModel: Module {
    @ModuleInfo(key: "embeddings") var embeddings: NEOVisionEmbeddings

    public init(_ config: VisionConfig) {
        self._embeddings.wrappedValue = NEOVisionEmbeddings(config)
        super.init()
    }

    public func callAsFunction(_ pixels: MLXArray, gridH: Int, gridW: Int) -> MLXArray {
        embeddings(pixels, gridH: gridH, gridW: gridW)
    }
}
