// Qwen3MoT.swift — mirrors modeling_qwen3.py (NEO-Unify MoT fork of Qwen3).
//
// One 42-layer transformer carrying TWO weight sets per layer ("Mixture of
// Transformers"): understanding (`q_proj`, `mlp`, ...) and generation
// (`*_mot_gen`). Every forward call is stream-homogeneous — the reference's
// mixed und/gen path raises NotImplementedError and is deliberately NOT ported.
//
// Positions are 3-axis (t, h, w); head_dim 128 splits [t:64 | h:32 | w:32].
// ⚠ RoPE frequency-range trick (`_rope_init_fn_keep_freq_range`): each axis'
// inv_freq is computed at DOUBLE the axis dim and subsampled [::2] — see
// DualAxisRotary below. A generic rope init is silently wrong here.

import Foundation
import MLX
import MLXFast
import MLXNN

public enum MoTStream: Sendable {
    case und  // text / understanding-image tokens
    case gen  // image-generation (denoise) tokens
}

/// Per-layer KV pair, layout [B, H_kv, S, D] (kept identical to the reference).
public typealias KVPair = (keys: MLXArray, values: MLXArray)

// MARK: - RoPE

/// Rotary tables for one axis, reproducing the reference's `[::2]` trick:
/// `inv_freq = theta ** (-arange(0, 2*dim, 4) / (2*dim))` (dim = rotary dims).
/// Rotation style: rotate_half (NeoX), cos/sin computed in fp32.
public struct DualAxisRotary {
    public let invFreq: MLXArray  // (dim/2,) fp32
    public let dim: Int

    public init(dim: Int, theta: Float) {
        self.dim = dim
        let doubled = 2 * dim
        let exponents = MLXArray(stride(from: 0, to: doubled, by: 4).map { Float($0) / Float(doubled) })
        self.invFreq = 1.0 / MLX.pow(MLXArray(theta), exponents)
    }

    /// positions: (S,) integer array → (cos, sin) each (1, 1, S, dim) fp32.
    public func cosSin(positions: MLXArray) -> (MLXArray, MLXArray) {
        let pos = positions.asType(.float32).reshaped([-1, 1])          // (S, 1)
        let freqs = pos * invFreq.reshaped([1, -1])                     // (S, dim/2)
        let emb = concatenated([freqs, freqs], axis: -1)                // (S, dim)
        let cos = MLX.cos(emb).reshaped([1, 1, emb.dim(0), dim])
        let sin = MLX.sin(emb).reshaped([1, 1, emb.dim(0), dim])
        return (cos, sin)
    }
}

@inline(__always)
func rotateHalf(_ x: MLXArray) -> MLXArray {
    let parts = x.split(parts: 2, axis: -1)
    return concatenated([-parts[1], parts[0]], axis: -1)
}

/// `q*cos + rotate_half(q)*sin` with fp32 cos/sin cast to the activation dtype.
@inline(__always)
func applyRotary(_ x: MLXArray, cos: MLXArray, sin: MLXArray) -> MLXArray {
    x * cos.asType(x.dtype) + rotateHalf(x) * sin.asType(x.dtype)
}

// MARK: - Masks

/// `create_block_causal_mask`: allow attention where `t_j == t_i` (same
/// temporal block — e.g. all patches of one image) OR `pos_j <= pos_i`
/// (positional causality). Additive 0 / -inf, shape (1, 1, S, S), fp32 —
/// cast to the activation dtype before SDPA (fused-path mask dtype rule).
public func createBlockCausalMask(tIndexes: MLXArray) -> MLXArray {
    let s = tIndexes.dim(0)
    let ti = tIndexes.reshaped([s, 1])
    let tj = tIndexes.reshaped([1, s])
    let pos = MLXArray(Int32(0) ..< Int32(s))
    let pi = pos.reshaped([s, 1])
    let pj = pos.reshaped([1, s])
    let allowed = (tj .== ti) .|| (pj .<= pi)
    let zeros = MLXArray.zeros([s, s], type: Float.self)
    let negInf = MLXArray.full([s, s], values: MLXArray(-Float.infinity))
    return MLX.which(allowed, zeros, negInf).reshaped([1, 1, s, s])
}

// MARK: - Attention

/// 3-axis indexes for a token run.
public struct THWIndexes {
    public var t: MLXArray  // (S,)
    public var h: MLXArray  // (S,)
    public var w: MLXArray  // (S,)
    public init(t: MLXArray, h: MLXArray, w: MLXArray) { self.t = t; self.h = h; self.w = w }
}

public final class MoTAttention: Module {
    let numHeads: Int
    let numKVHeads: Int
    let headDim: Int
    let scale: Float

    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "k_proj") var kProj: Linear
    @ModuleInfo(key: "v_proj") var vProj: Linear
    @ModuleInfo(key: "o_proj") var oProj: Linear
    @ModuleInfo(key: "q_proj_mot_gen") var qProjGen: Linear
    @ModuleInfo(key: "k_proj_mot_gen") var kProjGen: Linear
    @ModuleInfo(key: "v_proj_mot_gen") var vProjGen: Linear
    @ModuleInfo(key: "o_proj_mot_gen") var oProjGen: Linear

    // RMSNorm over each 64-dim half (t-half and hw-half), applied BEFORE the
    // h|w split and BEFORE RoPE — matching the reference exactly.
    @ModuleInfo(key: "q_norm") var qNorm: RMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: RMSNorm
    @ModuleInfo(key: "q_norm_hw") var qNormHW: RMSNorm
    @ModuleInfo(key: "k_norm_hw") var kNormHW: RMSNorm
    @ModuleInfo(key: "q_norm_mot_gen") var qNormGen: RMSNorm
    @ModuleInfo(key: "k_norm_mot_gen") var kNormGen: RMSNorm
    @ModuleInfo(key: "q_norm_hw_mot_gen") var qNormHWGen: RMSNorm
    @ModuleInfo(key: "k_norm_hw_mot_gen") var kNormHWGen: RMSNorm

    let rotaryT: DualAxisRotary   // 64 dims, theta 5e6
    let rotaryHW: DualAxisRotary  // 32 dims, theta 1e4 (shared by h and w)

    public init(_ config: LLMConfig) {
        self.numHeads = config.numAttentionHeads
        self.numKVHeads = config.numKeyValueHeads
        self.headDim = config.headDim
        self.scale = 1.0 / Float(config.headDim).squareRoot()

        let qOut = config.numAttentionHeads * config.headDim
        let kvOut = config.numKeyValueHeads * config.headDim
        self._qProj.wrappedValue = Linear(config.hiddenSize, qOut, bias: config.attentionBias)
        self._kProj.wrappedValue = Linear(config.hiddenSize, kvOut, bias: config.attentionBias)
        self._vProj.wrappedValue = Linear(config.hiddenSize, kvOut, bias: config.attentionBias)
        self._oProj.wrappedValue = Linear(qOut, config.hiddenSize, bias: config.attentionBias)
        self._qProjGen.wrappedValue = Linear(config.hiddenSize, qOut, bias: config.attentionBias)
        self._kProjGen.wrappedValue = Linear(config.hiddenSize, kvOut, bias: config.attentionBias)
        self._vProjGen.wrappedValue = Linear(config.hiddenSize, kvOut, bias: config.attentionBias)
        self._oProjGen.wrappedValue = Linear(qOut, config.hiddenSize, bias: config.attentionBias)

        let half = config.headDim / 2
        self._qNorm.wrappedValue = RMSNorm(dimensions: half, eps: config.rmsNormEps)
        self._kNorm.wrappedValue = RMSNorm(dimensions: half, eps: config.rmsNormEps)
        self._qNormHW.wrappedValue = RMSNorm(dimensions: half, eps: config.rmsNormEps)
        self._kNormHW.wrappedValue = RMSNorm(dimensions: half, eps: config.rmsNormEps)
        self._qNormGen.wrappedValue = RMSNorm(dimensions: half, eps: config.rmsNormEps)
        self._kNormGen.wrappedValue = RMSNorm(dimensions: half, eps: config.rmsNormEps)
        self._qNormHWGen.wrappedValue = RMSNorm(dimensions: half, eps: config.rmsNormEps)
        self._kNormHWGen.wrappedValue = RMSNorm(dimensions: half, eps: config.rmsNormEps)

        self.rotaryT = DualAxisRotary(dim: config.headDim / 2, theta: config.ropeTheta)
        self.rotaryHW = DualAxisRotary(dim: config.headDim / 4, theta: config.ropeThetaHW)
        super.init()
    }

    /// Returns (attnOutput, currentKV). `currentKV` is the *un-concatenated*
    /// KV of the tokens in `x` — the caller stores it at prefill and drops it
    /// during denoise (reference `update_cache=False` semantics).
    public func callAsFunction(
        _ x: MLXArray,
        stream: MoTStream,
        indexes: THWIndexes,
        mask: MLXArray?,
        prefixKV: KVPair?
    ) -> (MLXArray, KVPair) {
        let (b, s) = (x.dim(0), x.dim(1))

        let (qp, kp, vp, op): (Linear, Linear, Linear, Linear) =
            stream == .und ? (qProj, kProj, vProj, oProj) : (qProjGen, kProjGen, vProjGen, oProjGen)
        let (qnT, knT, qnHW, knHW): (RMSNorm, RMSNorm, RMSNorm, RMSNorm) =
            stream == .und ? (qNorm, kNorm, qNormHW, kNormHW) : (qNormGen, kNormGen, qNormHWGen, kNormHWGen)

        // q: (B, S, H, D) → norm halves → (B, H, S, ·) → split hw
        let qs = qp(x).reshaped([b, s, numHeads, headDim])
        let qParts = qs.split(parts: 2, axis: -1)
        let qT = qnT(qParts[0]).transposed(0, 2, 1, 3)
        let qHW = qnHW(qParts[1]).transposed(0, 2, 1, 3)
        let qHWParts = qHW.split(parts: 2, axis: -1)

        let ks = kp(x).reshaped([b, s, numKVHeads, headDim])
        let kParts = ks.split(parts: 2, axis: -1)
        let kT = knT(kParts[0]).transposed(0, 2, 1, 3)
        let kHW = knHW(kParts[1]).transposed(0, 2, 1, 3)
        let kHWParts = kHW.split(parts: 2, axis: -1)

        let v = vp(x).reshaped([b, s, numKVHeads, headDim]).transposed(0, 2, 1, 3)

        let (cosT, sinT) = rotaryT.cosSin(positions: indexes.t)
        let (cosH, sinH) = rotaryHW.cosSin(positions: indexes.h)
        let (cosW, sinW) = rotaryHW.cosSin(positions: indexes.w)

        let q = concatenated(
            [
                applyRotary(qT, cos: cosT, sin: sinT),
                applyRotary(qHWParts[0], cos: cosH, sin: sinH),
                applyRotary(qHWParts[1], cos: cosW, sin: sinW),
            ], axis: -1)
        let k = concatenated(
            [
                applyRotary(kT, cos: cosT, sin: sinT),
                applyRotary(kHWParts[0], cos: cosH, sin: sinH),
                applyRotary(kHWParts[1], cos: cosW, sin: sinW),
            ], axis: -1)

        var kAll = k
        var vAll = v
        if let prefix = prefixKV {
            kAll = concatenated([prefix.keys, k], axis: 2)
            vAll = concatenated([prefix.values, v], axis: 2)
        }

        let sdpaMask = mask.map { $0.asType(q.dtype) }
        var out = MLXFast.scaledDotProductAttention(
            queries: q, keys: kAll, values: vAll, scale: scale, mask: sdpaMask)
        out = out.transposed(0, 2, 1, 3).reshaped([b, s, numHeads * headDim])
        return (op(out), (k, v))
    }
}

// MARK: - MLP

public final class MoTMLP: Module {
    @ModuleInfo(key: "gate_proj") var gateProj: Linear
    @ModuleInfo(key: "up_proj") var upProj: Linear
    @ModuleInfo(key: "down_proj") var downProj: Linear

    public init(_ config: LLMConfig) {
        self._gateProj.wrappedValue = Linear(config.hiddenSize, config.intermediateSize, bias: false)
        self._upProj.wrappedValue = Linear(config.hiddenSize, config.intermediateSize, bias: false)
        self._downProj.wrappedValue = Linear(config.intermediateSize, config.hiddenSize, bias: false)
        super.init()
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        Self.downProjected(downProj, silu(gateProj(x)) * upProj(x))
    }

    /// mlx-swift ≤ 0.31.6 (JIT builds) mis-instantiates the NAX split-K GEMM
    /// (mlx#3797, fixed by #3810): any HALF-PRECISION matmul with
    /// M·N ≥ 2048², K ≥ 10240, K ≥ 3·max(M,N) returns garbage/NaN on M5-class
    /// GPUs. In this model that is exactly the FFN down-projection (K = 12288)
    /// once the image-token sequence passes ~896 rows — 1024² denoise = 1024
    /// tokens → 100% NaN output. Row-chunking at ≤896 rows is exact (same
    /// reduction, different tiling). Remove when an mlx-swift release vendors
    /// the fix (0.31.6 is still the latest as of 2026-08-23; re-probe on bump —
    /// same playbook as boogu-image-swift's LuminaFeedForward.downProjected).
    static func downProjected(_ proj: Linear, _ h: MLXArray) -> MLXArray {
        let s = h.dim(-2)
        let halfPrecision = h.dtype == .bfloat16 || h.dtype == .float16
        guard halfPrecision, s > 896, h.dim(-1) >= 10240 else { return proj(h) }
        var outs: [MLXArray] = []
        var i = 0
        while i < s {
            let j = min(i + 896, s)
            outs.append(proj(h[0..., i ..< j, 0...]))
            i = j
        }
        return concatenated(outs, axis: -2)
    }
}

// MARK: - Decoder layer

public final class MoTDecoderLayer: Module {
    @ModuleInfo(key: "self_attn") var selfAttn: MoTAttention
    @ModuleInfo(key: "mlp") var mlp: MoTMLP
    @ModuleInfo(key: "mlp_mot_gen") var mlpGen: MoTMLP
    @ModuleInfo(key: "input_layernorm") var inputLayernorm: RMSNorm
    @ModuleInfo(key: "input_layernorm_mot_gen") var inputLayernormGen: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayernorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm_mot_gen") var postAttentionLayernormGen: RMSNorm

    public init(_ config: LLMConfig) {
        self._selfAttn.wrappedValue = MoTAttention(config)
        self._mlp.wrappedValue = MoTMLP(config)
        self._mlpGen.wrappedValue = MoTMLP(config)
        self._inputLayernorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self._inputLayernormGen.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self._postAttentionLayernorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self._postAttentionLayernormGen.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        super.init()
    }

    public func callAsFunction(
        _ x: MLXArray,
        stream: MoTStream,
        indexes: THWIndexes,
        mask: MLXArray?,
        prefixKV: KVPair?
    ) -> (MLXArray, KVPair) {
        let inNorm = stream == .und ? inputLayernorm : inputLayernormGen
        let postNorm = stream == .und ? postAttentionLayernorm : postAttentionLayernormGen
        let ffn = stream == .und ? mlp : mlpGen

        var residual = x
        let (attnOut, kv) = selfAttn(inNorm(x), stream: stream, indexes: indexes, mask: mask, prefixKV: prefixKV)
        var h = residual + attnOut

        residual = h
        h = residual + ffn(postNorm(h))
        return (h, kv)
    }
}

// MARK: - Model

public final class Qwen3MoTModel: Module {
    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    @ModuleInfo(key: "layers") var layers: [MoTDecoderLayer]
    @ModuleInfo(key: "norm") var norm: RMSNorm
    @ModuleInfo(key: "norm_mot_gen") var normGen: RMSNorm

    public init(_ config: LLMConfig) {
        self._embedTokens.wrappedValue = Embedding(embeddingCount: config.vocabSize, dimensions: config.hiddenSize)
        self._layers.wrappedValue = (0 ..< config.numHiddenLayers).map { _ in MoTDecoderLayer(config) }
        self._norm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self._normGen.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        super.init()
    }

    /// - Parameters:
    ///   - prefixKV: per-layer cached KV to attend over (not mutated).
    ///   - collectKV: return this call's per-layer KV (prefill) or not (denoise).
    /// - Returns: final-norm'd hidden states (+ per-layer KV when collected).
    public func callAsFunction(
        embeds: MLXArray,
        stream: MoTStream,
        indexes: THWIndexes,
        mask: MLXArray?,
        prefixKV: [KVPair]? = nil,
        collectKV: Bool = false,
        evalEvery: Int = 8
    ) -> (hidden: MLXArray, kv: [KVPair]) {
        var h = embeds
        var collected: [KVPair] = []
        collected.reserveCapacity(collectKV ? layers.count : 0)
        for (i, layer) in layers.enumerated() {
            let (out, kv) = layer(h, stream: stream, indexes: indexes, mask: mask, prefixKV: prefixKV?[i])
            h = out
            if collectKV { collected.append(kv) }
            // Metal command-buffer discipline on 42-layer × long-seq graphs.
            if evalEvery > 0, (i + 1) % evalEvery == 0 { eval(h) }
        }
        let finalNorm = stream == .und ? norm : normGen
        return (finalNorm(h), collected)
    }
}

public final class Qwen3MoTForCausalLM: Module {
    @ModuleInfo(key: "model") var model: Qwen3MoTModel
    @ModuleInfo(key: "lm_head") var lmHead: Linear

    public init(_ config: LLMConfig) {
        self._model.wrappedValue = Qwen3MoTModel(config)
        self._lmHead.wrappedValue = Linear(config.hiddenSize, config.vocabSize, bias: false)
        super.init()
    }
}
