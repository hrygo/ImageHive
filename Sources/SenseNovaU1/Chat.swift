// Chat.swift — autoregressive text decode on the und stream: VQA/chat
// (`chat` + HF-generate-equivalent greedy loop) and the T2I think mode's
// text phase (`_generate_think` / `_append_text_tokens_to_cache`).
//
// Reference decode semantics: each generated token gets t = (running max)+1,
// h = w = 0; a single query token with the full cache needs no mask (causality
// is trivial); logits = lm_head(und-normed hidden). Think mode stops at
// `</think>` (forwarded into the cache, then break) or eos; chat stops at
// `<|im_end|>`.

import Foundation
import MLX
import MLXNN
import MLXRandom

public enum ChatToken {
    public static let imEnd: Int32 = 151645
    public static let thinkEnd: Int32 = 151668
}

public struct SamplingParams: Sendable {
    public var temperature: Float = 0  // 0 = greedy
    public var topP: Float = 1.0
    public var topK: Int = 0
    public var maxNewTokens = 1024
    public var seed: UInt64 = 0
    public init() {}
}

/// Growing per-layer KV for AR decode (reference `update_cache=True` path).
public final class MutableKVCache {
    public private(set) var layers: [KVPair]
    public init(prefix: [KVPair]) { self.layers = prefix }
    public var length: Int { layers.first.map { $0.keys.dim(2) } ?? 0 }

    func extend(with new: [KVPair]) {
        for i in layers.indices {
            layers[i] = (
                concatenated([layers[i].keys, new[i].keys], axis: 2),
                concatenated([layers[i].values, new[i].values], axis: 2)
            )
        }
    }
}

extension NEOChatModel {

    /// und-stream prefill from spliced embeds, returning logits of the LAST
    /// position (`logits_to_keep=1`) plus the cache and max temporal index.
    func prefillForDecode(
        embeds: MLXArray, indexes: THWIndexes, mask: MLXArray
    ) -> (cache: MutableKVCache, lastLogits: MLXArray, maxT: Int32) {
        let (hidden, kv) = languageModel.model(
            embeds: embeds, stream: .und, indexes: indexes, mask: mask, collectKV: true)
        let last = hidden[0..., (hidden.dim(1) - 1) ..< hidden.dim(1), 0...]
        let logits = languageModel.lmHead(last)
        eval(logits)
        let maxT = indexes.t.max().item(Int32.self)
        return (MutableKVCache(prefix: kv), logits, maxT)
    }

    /// One und-stream decode step: token → logits over the grown cache.
    func decodeStep(
        token: Int32, t: Int32, cache: MutableKVCache
    ) -> MLXArray {
        let embeds = languageModel.model.embedTokens(MLXArray([token]).reshaped([1, 1]))
        let indexes = THWIndexes(
            t: MLXArray([t]), h: MLXArray([Int32(0)]), w: MLXArray([Int32(0)]))
        let (hidden, kv) = languageModel.model(
            embeds: embeds, stream: .und, indexes: indexes, mask: nil,
            prefixKV: cache.layers, collectKV: true, evalEvery: 0)
        cache.extend(with: kv)
        return languageModel.lmHead(hidden[0..., 0 ..< 1, 0...])
    }

    func sample(_ logits: MLXArray, params: SamplingParams) -> Int32 {
        let flat = logits.reshaped([-1]).asType(.float32)
        if params.temperature <= 0 {
            return flat.argMax().item(Int32.self)
        }
        var scaled = flat / params.temperature
        if params.topK > 0 {
            let sorted = MLX.sorted(scaled)  // ascending
            let cutoff = sorted[sorted.dim(0) - params.topK]
            scaled = MLX.which(scaled .< cutoff, MLXArray(-Float.infinity), scaled)
        }
        if params.topP < 1.0 {
            let order = argSort(scaled)  // ascending
            let probs = softmax(scaled, axis: -1)
            let sortedProbs = probs[order]
            let cum = cumsum(sortedProbs, axis: 0)
            // keep the top tokens whose (descending) cumulative prob ≤ topP
            let keepMaskSorted = cum .> (1.0 - params.topP)
            var mask = MLXArray.zeros([scaled.dim(0)], type: Bool.self)
            mask[order] = keepMaskSorted
            scaled = MLX.which(mask, scaled, MLXArray(-Float.infinity))
        }
        return MLXRandom.categorical(scaled.reshaped([1, -1])).item(Int32.self)
    }

    /// Greedy/sampled AR decode until a stop token. Returns generated ids
    /// (stop token excluded) and the final temporal index. The cache grows
    /// in place (mirrors `_generate_think` — pass `forwardStopIntoCache` for
    /// think mode's `</think>` handling).
    public func generateText(
        cache: MutableKVCache,
        firstLogits: MLXArray,
        startT: Int32,
        stopTokens: Set<Int32>,
        forwardStopIntoCache: Set<Int32> = [],
        params: SamplingParams = SamplingParams(),
        onToken: ((Int32) -> Void)? = nil
    ) throws -> (tokens: [Int32], t: Int32) {
        if params.temperature > 0 { MLXRandom.seed(params.seed) }
        // reference: `current_index = t_idx` then the forward INCREMENTS before
        // use — each new token's temporal index is (running max) + 1.
        var t = startT
        var next = sample(firstLogits, params: params)
        var out: [Int32] = []
        for _ in 0 ..< params.maxNewTokens {
            try Task.checkCancellation()  // CAN cadence: per generated token
            if stopTokens.contains(next) {
                if forwardStopIntoCache.contains(next) {
                    _ = decodeStep(token: next, t: t + 1, cache: cache)
                    t += 1
                    out.append(next)
                }
                break
            }
            out.append(next)
            onToken?(next)
            let logits = decodeStep(token: next, t: t + 1, cache: cache)
            t += 1
            next = sample(logits, params: params)
        }
        return (out, t)
    }

    /// `_append_text_tokens_to_cache`: run known ids through the und stream to
    /// grow the cache (t advancing, h = w = 0).
    public func appendTextToCache(
        _ ids: [Int32], cache: MutableKVCache, startT: Int32
    ) -> Int32 {
        guard !ids.isEmpty else { return startT }
        let s = ids.count
        let embeds = languageModel.model.embedTokens(MLXArray(ids).reshaped([1, s]))
        let tIdx = MLXArray((0 ..< s).map { startT + 1 + Int32($0) })
        let zeros = MLXArray([Int32](repeating: 0, count: s))
        let indexes = THWIndexes(t: tIdx, h: zeros, w: zeros)
        // causal within the appended block; full attention over the cache
        let sInt = s
        let block = createBlockCausalMask(tIndexes: tIdx)
        let past = cache.length
        let full = concatenated(
            [MLXArray.zeros([1, 1, sInt, past], type: Float.self), block], axis: 3)
        let (_, kv) = languageModel.model(
            embeds: embeds, stream: .und, indexes: indexes, mask: full,
            prefixKV: cache.layers, collectKV: true, evalEvery: 0)
        cache.extend(with: kv)
        return startT + Int32(s)
    }

    /// VQA / chat: image-conditioned question → greedy answer ids.
    /// Build `ids` with `Conversation.buildPrompt` (+ image expansion) and
    /// tokenize outside; decode stops at `<|im_end|>`.
    public func chat(
        ids: [Int32],
        images: [EditImage] = [],
        params: SamplingParams = SamplingParams(),
        onToken: ((Int32) -> Void)? = nil
    ) throws -> [Int32] {
        let (embeds, indexes, mask, _) =
            images.isEmpty
            ? textOnlyInputs(ids: ids)
            : buildIT2IInputs(ids: ids, images: images)
        let (cache, logits, maxT) = prefillForDecode(embeds: embeds, indexes: indexes, mask: mask)
        let (tokens, _) = try generateText(
            cache: cache, firstLogits: logits, startT: maxT,
            stopTokens: [ChatToken.imEnd], params: params, onToken: onToken)
        return tokens
    }

    /// Think-mode T2I: AR-generate a `<think>…</think>` block first, append
    /// `\n\n<img>`, then denoise against the grown cond cache (reference
    /// `t2i_generate(think_mode=True)` flow).
    /// - condThinkIds: cond prompt built with `appendText: "<think>\n"`.
    /// - imgSuffixIds: tokenized `"\n\n<img>"`.
    public func t2iGenerateThink(
        condThinkIds: [Int32],
        uncondIds: [Int32]?,
        imgSuffixIds: [Int32],
        width: Int,
        height: Int,
        params: T2IParams = T2IParams(),
        sampling: SamplingParams = SamplingParams(),
        injectedNoise: MLXArray? = nil,
        onToken: ((Int32) -> Void)? = nil,
        onStep: ((Int, Int) -> Void)? = nil
    ) throws -> (image: MLXArray, thinkIds: [Int32]) {
        let (embeds, indexes, mask, _) = textOnlyInputs(ids: condThinkIds)
        let (cache, logits, maxT) = prefillForDecode(embeds: embeds, indexes: indexes, mask: mask)
        let (thinkIds, tAfterThink) = try generateText(
            cache: cache, firstLogits: logits, startT: maxT,
            stopTokens: [ChatToken.imEnd, ChatToken.thinkEnd],
            forwardStopIntoCache: [ChatToken.thinkEnd],
            params: sampling, onToken: onToken)
        let tFinal = appendTextToCache(imgSuffixIds, cache: cache, startT: tAfterThink)

        let needsCFG = params.cfgScale > 1 && uncondIds != nil
        let prefixUncond = needsCFG ? prefillText(uncondIds!) : []
        let image = try t2iDenoise(
            prefixCond: cache.layers, condImageT: tFinal + 1,
            prefixUncond: prefixUncond,
            uncondImageT: needsCFG ? Int32(uncondIds!.count) : 0,
            needsCFG: needsCFG, width: width, height: height, params: params,
            injectedNoise: injectedNoise, onStep: onStep)
        return (image, thinkIds)
    }

    func textOnlyInputs(ids: [Int32]) -> (MLXArray, THWIndexes, MLXArray, Int32) {
        let s = ids.count
        let t = MLXArray(ids.indices.map { Int32($0) })
        let zeros = MLXArray([Int32](repeating: 0, count: s))
        let indexes = THWIndexes(t: t, h: zeros, w: zeros)
        let mask = createBlockCausalMask(tIndexes: t)
        let embeds = languageModel.model.embedTokens(MLXArray(ids).reshaped([1, s]))
        return (embeds, indexes, mask, Int32(s - 1))
    }
}
