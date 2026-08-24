// FMModules.swift — mirrors modeling_fm_modules.py (only the classes the
// U1.5-8B checkpoint actually uses: TimestepEmbedder ×2 + ConvDecoder).
// The deep FM heads / NerfEmbedder / alternate decoders are dead code upstream.

import Foundation
import MLX
import MLXNN

/// GLIDE-style sinusoidal timestep embedder.
/// ⚠ raw t ∈ [0,1] (NO ×1000), [cos | sin] order (cos FIRST), sinusoid in fp32,
/// MLP computed in the weight dtype (bf16 after load-cast).
/// Checkpoint keys `mlp.0` / `mlp.2` (torch Sequential) are remapped to
/// `mlp.0` / `mlp.1` by the weight sanitizer (the SiLU holds index 1 upstream).
public final class TimestepEmbedder: Module {
    @ModuleInfo(key: "mlp") var mlp: [Linear]
    let frequencyEmbeddingSize: Int

    public init(hiddenSize: Int, frequencyEmbeddingSize: Int = 256) {
        self.frequencyEmbeddingSize = frequencyEmbeddingSize
        self._mlp.wrappedValue = [
            Linear(frequencyEmbeddingSize, hiddenSize, bias: true),
            Linear(hiddenSize, hiddenSize, bias: true),
        ]
        super.init()
    }

    /// t: (N,) → (N, dim) fp32
    public static func timestepEmbedding(_ t: MLXArray, dim: Int, maxPeriod: Float = 10_000) -> MLXArray {
        let half = dim / 2
        let exponents = MLXArray((0 ..< half).map { -log(maxPeriod) * Float($0) / Float(half) })
        let freqs = MLX.exp(exponents)                                  // (half,)
        let args = t.asType(.float32).reshaped([-1, 1]) * freqs.reshaped([1, -1])
        return concatenated([MLX.cos(args), MLX.sin(args)], axis: -1)   // cos first!
    }

    public func callAsFunction(_ t: MLXArray) -> MLXArray {
        let freq = Self.timestepEmbedding(t, dim: frequencyEmbeddingSize)
        let x = freq.asType(mlp[0].weight.dtype)
        return mlp[1](silu(mlp[0](x)))
    }
}

/// PyTorch `nn.PixelShuffle(r)` in NHWC:
/// in (B, H, W, C·r²) with channel index c·r² + i·r + j
/// → out (B, H·r, W·r, C), out[b, h·r+i, w·r+j, c] = in[b, h, w, c·r²+i·r+j].
@inline(__always)
public func pixelShuffleNHWC(_ x: MLXArray, _ r: Int) -> MLXArray {
    let (b, h, w, crr) = (x.dim(0), x.dim(1), x.dim(2), x.dim(3))
    let c = crr / (r * r)
    return x.reshaped([b, h, w, c, r, r])
        .transposed(0, 1, 4, 2, 5, 3)
        .reshaped([b, h * r, w * r, c])
}

/// The pixel head (`fm_modules.fm_head`): token-grid hidden states → RGB.
/// PS(2) → Conv(1024→1024, 3×3) → GELU → PS(2) → Conv(256→192, 3×3) → PS(8).
/// Runs NHWC end-to-end (conv weights transposed at load).
public final class ConvDecoder: Module {
    @ModuleInfo(key: "conv1") var conv1: Conv2d
    @ModuleInfo(key: "conv2") var conv2: Conv2d

    public init(inputDim: Int = 4096, hiddenDim: Int = 1024) {
        self._conv1.wrappedValue = Conv2d(
            inputChannels: inputDim / 4, outputChannels: hiddenDim,
            kernelSize: 3, padding: 1)
        self._conv2.wrappedValue = Conv2d(
            inputChannels: hiddenDim / 4, outputChannels: 192,
            kernelSize: 3, padding: 1)
        super.init()
    }

    /// x: (B, tokenH, tokenW, 4096) NHWC → (B, 32·tokenH, 32·tokenW, 3) NHWC
    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = pixelShuffleNHWC(x, 2)          // (B, 2th, 2tw, 1024)
        h = gelu(conv1(h))                      // exact (erf) GELU, as nn.GELU()
        h = pixelShuffleNHWC(h, 2)              // (B, 4th, 4tw, 256)
        h = conv2(h)                            // (B, 4th, 4tw, 192)
        return pixelShuffleNHWC(h, 8)           // (B, 32th, 32tw, 3)
    }
}

/// Container matching the `fm_modules.*` checkpoint namespace.
public final class FMModules: Module {
    @ModuleInfo(key: "vision_model_mot_gen") var visionGen: NEOVisionModel
    @ModuleInfo(key: "timestep_embedder") var timestepEmbedder: TimestepEmbedder
    @ModuleInfo(key: "noise_scale_embedder") var noiseScaleEmbedder: TimestepEmbedder
    @ModuleInfo(key: "fm_head") var fmHead: ConvDecoder

    public init(_ config: NEOChatConfig) {
        self._visionGen.wrappedValue = NEOVisionModel(config.vision)
        self._timestepEmbedder.wrappedValue = TimestepEmbedder(hiddenSize: config.llm.hiddenSize)
        self._noiseScaleEmbedder.wrappedValue = TimestepEmbedder(hiddenSize: config.llm.hiddenSize)
        self._fmHead.wrappedValue = ConvDecoder(inputDim: config.llm.hiddenSize)
        super.init()
    }
}
