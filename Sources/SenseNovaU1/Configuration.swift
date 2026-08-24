// Configuration.swift — mirrors configuration_neo_chat.py / configuration_neo_vit.py.
// Values are read from the checkpoint's config.json; defaults here match the
// reference config classes ONLY where config.json omits a field (resolved-config
// rule: never trust a hand default over the shipped json).

import Foundation

public struct LLMConfig: Sendable {
    public var hiddenSize = 4096
    public var intermediateSize = 12288
    public var numHiddenLayers = 42
    public var numAttentionHeads = 32
    public var numKeyValueHeads = 8
    public var headDim = 128
    public var rmsNormEps: Float = 1e-6
    public var vocabSize = 151936
    public var ropeTheta: Float = 5_000_000.0
    public var ropeThetaHW: Float = 10_000.0
    public var attentionBias = false
    public var tieWordEmbeddings = false
}

public struct VisionConfig: Sendable {
    public var hiddenSize = 1024        // patch embed dim
    public var llmHiddenSize = 4096
    public var patchSize = 16
    public var downsampleRatio: Float = 0.5
    public var numChannels = 3
    public var ropeThetaVision: Float = 10_000.0
    public var maxPositionEmbeddingsVision = 10_000
}

public struct NEOChatConfig: Sendable {
    public var llm = LLMConfig()
    public var vision = VisionConfig()
    public var downsampleRatio: Float = 0.5   // top-level (== vision's)
    public var patchSize = 16
    // flow-matching knobs actually LIVE at inference defaults, not config
    // (trap ledger #4/#5): timestep_shift 3.0 and t_eps 0.02 come from the
    // CLI/driver; config's 1.0 / 0.05 are overridden by the reference.
    public var noiseScale: Float = 1.0
    public var noiseScaleBaseImageSeqLen: Float = 64
    public var noiseScaleMaxValue: Float = 16.0
    public var addNoiseScaleEmbedding = true
    public var usePixelHead = true

    /// tokens are (patchSize / downsampleRatio) = 32 px square
    public var pixelsPerToken: Int { Int(Float(patchSize) / downsampleRatio) }
    public var mergeSize: Int { Int(1.0 / downsampleRatio) }

    public init() {}

    /// Decode from the checkpoint's config.json (tolerant: unknown keys ignored).
    public static func load(from directory: URL) throws -> NEOChatConfig {
        let data = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SenseNovaError.badConfig("config.json is not a JSON object")
        }
        var cfg = NEOChatConfig()
        func f(_ d: [String: Any], _ k: String) -> Float? { (d[k] as? NSNumber)?.floatValue }
        func i(_ d: [String: Any], _ k: String) -> Int? { (d[k] as? NSNumber)?.intValue }
        func b(_ d: [String: Any], _ k: String) -> Bool? { d[k] as? Bool }

        if let v = f(root, "downsample_ratio") { cfg.downsampleRatio = v }
        if let v = i(root, "patch_size") { cfg.patchSize = v }
        if let v = f(root, "noise_scale") { cfg.noiseScale = v }
        if let v = f(root, "noise_scale_base_image_seq_len") { cfg.noiseScaleBaseImageSeqLen = v }
        if let v = f(root, "noise_scale_max_value") { cfg.noiseScaleMaxValue = v }
        if let v = b(root, "add_noise_scale_embedding") { cfg.addNoiseScaleEmbedding = v }
        if let v = b(root, "use_pixel_head") { cfg.usePixelHead = v }

        if let llm = root["llm_config"] as? [String: Any] {
            if let v = i(llm, "hidden_size") { cfg.llm.hiddenSize = v }
            if let v = i(llm, "intermediate_size") { cfg.llm.intermediateSize = v }
            if let v = i(llm, "num_hidden_layers") { cfg.llm.numHiddenLayers = v }
            if let v = i(llm, "num_attention_heads") { cfg.llm.numAttentionHeads = v }
            if let v = i(llm, "num_key_value_heads") { cfg.llm.numKeyValueHeads = v }
            if let v = i(llm, "head_dim") { cfg.llm.headDim = v }
            if let v = f(llm, "rms_norm_eps") { cfg.llm.rmsNormEps = v }
            if let v = i(llm, "vocab_size") { cfg.llm.vocabSize = v }
            if let v = f(llm, "rope_theta") { cfg.llm.ropeTheta = v }
            if let v = f(llm, "rope_theta_hw") { cfg.llm.ropeThetaHW = v }
            if let v = b(llm, "attention_bias") { cfg.llm.attentionBias = v }
            if let v = b(llm, "tie_word_embeddings") { cfg.llm.tieWordEmbeddings = v }
        }
        if let vis = root["vision_config"] as? [String: Any] {
            if let v = i(vis, "hidden_size") { cfg.vision.hiddenSize = v }
            if let v = i(vis, "llm_hidden_size") { cfg.vision.llmHiddenSize = v }
            if let v = i(vis, "patch_size") { cfg.vision.patchSize = v }
            if let v = f(vis, "downsample_ratio") { cfg.vision.downsampleRatio = v }
            if let v = i(vis, "num_channels") { cfg.vision.numChannels = v }
            if let v = f(vis, "rope_theta_vision") { cfg.vision.ropeThetaVision = v }
            if let v = i(vis, "max_position_embeddings_vision") { cfg.vision.maxPositionEmbeddingsVision = v }
        }
        return cfg
    }
}

public enum SenseNovaError: Error {
    case badConfig(String)
    case badWeights(String)
}
