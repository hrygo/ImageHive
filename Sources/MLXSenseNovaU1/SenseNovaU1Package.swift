// MLXEngine package over the SenseNovaU1 core — one resident unified model
// serving `textToImage` AND `imageEdit` (VQA/imageAnalysis is a queued
// follow-up surface on the same core).
//
// SenseNova-U1.5-8B-MoT (Apache-2.0): NEO-unify Mixture-of-Transformers,
// pixel-space rectified flow, no VAE. The Swift core is parity-locked against
// the reference PyTorch implementation (components <1e-4; e2e per-pass cos
// 0.999+; edit e2e 34.6 dB) — this wrapper is a thin conformance layer.
//
// Weights are fetched from OUR mlx-community artifacts (fetch address), while
// `Provenance.sourceRepo` names the upstream ORIGIN — the split-provenance
// rule; `ProvenanceSplitTests` asserts the two never swap.

import CoreGraphics
import Foundation
import ImageIO
import MLX
import MLXToolKit
import SenseNovaU1
import UniformTypeIdentifiers

/// The published artifact tiers (mlx-community). `8step` tiers carry the
/// official 8-step distillation LoRA pre-merged and run cfg-free — fast T2I
/// only; use `bf16`/`q8` for 50-step quality T2I and editing.
public enum SenseNovaVariant: String, Codable, Sendable, CaseIterable {
    case bf16 = "bf16"
    case q8 = "8bit"
    case fast8 = "8step-8bit"
    case fast4 = "8step-4bit"

    public var repo: String { "mlx-community/SenseNova-U1.5-8B-MoT-\(rawValue)" }

    public var quant: Quant {
        switch self {
        case .bf16: return .bf16
        case .q8, .fast8: return .int8
        case .fast4: return .int4
        }
    }

    /// LoRA-merged distill tiers run cfg-free at 8 steps (the vendor contract).
    public var isDistilled: Bool { self == .fast8 || self == .fast4 }
    public var defaultSteps: Int { isDistilled ? 8 : 50 }
    public var defaultGuidance: Float { isDistilled ? 1.0 : 4.0 }
}

/// Init-time configuration (C9): variant + explicit snapshot override + defaults.
public struct SenseNovaU1Configuration:
    PackageConfiguration, ModelStorable, QuantConfigured, WeightSourcing
{
    public var variant: SenseNovaVariant
    /// Explicit artifact root (config.json + model-*.safetensors). Empty =
    /// resolve from the model store, materializing from `variant.repo` first run.
    public var snapshotPath: String
    public var modelsRootDirectory: URL?

    public var quant: Quant { variant.quant }

    /// Fresh-machine sources (MAT): one self-contained artifact per variant —
    /// quant-tiered configs exclude every byte their tier doesn't need by
    /// construction (each tier is its own repo).
    public var weightSources: [WeightSource] {
        [WeightSource(role: "model", repo: variant.repo, revision: "main", matching: ["*"])]
    }

    public func missingWeightSources(storeRoot: URL?) -> [WeightSource] {
        if !snapshotPath.isEmpty,
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: snapshotPath)
                    .appendingPathComponent("config.json").path)
        {
            return []
        }
        return defaultMissingWeightSources(storeRoot: storeRoot)
    }

    public func resolvedSnapshotDirectory(storeRoot: URL?) -> URL? {
        if !snapshotPath.isEmpty { return URL(fileURLWithPath: snapshotPath) }
        let store = ModelStore(root: storeRoot)
        let fm = FileManager.default
        if let flat = store.directory(for: variant.repo),
            fm.fileExists(atPath: flat.appendingPathComponent("config.json").path)
        {
            return flat
        }
        if let snap = store.snapshotDirectory(for: variant.repo, revision: "main"),
            fm.fileExists(atPath: snap.appendingPathComponent("config.json").path)
        {
            return snap
        }
        return store.directory(for: variant.repo)
    }

    public init(
        variant: SenseNovaVariant = .q8,
        snapshotPath: String = "",
        modelsRootDirectory: URL? = nil
    ) {
        self.variant = variant
        self.snapshotPath = snapshotPath
        self.modelsRootDirectory = modelsRootDirectory
    }

    private enum CodingKeys: String, CodingKey {
        case variant, snapshotPath
    }
}

public enum SenseNovaU1PackageError: Error, LocalizedError {
    case unreadableSnapshot(String)
    case imageDecode
    case pngEncode
    case distilledTierCannotEdit
    case distilledTierCannotThink
    case negativePromptUnsupportedOnEdit
    case sizeNotTokenAligned(width: Int, height: Int, multiple: Int)
    case distilledTierCannotAnalyze
    case metaDataOutOfRange(key: String, value: Double, range: ClosedRange<Double>)

    public var errorDescription: String? {
        switch self {
        case .unreadableSnapshot(let p): return "SenseNova artifact not readable at \(p)."
        case .imageDecode: return "Could not decode an input image."
        case .pngEncode: return "PNG encoding failed."
        case .distilledTierCannotEdit:
            return "The 8step distill tiers are T2I-only; use the bf16 or 8bit variant for imageEdit."
        case .distilledTierCannotThink:
            return "Think mode needs the base tiers; use the bf16 or 8bit variant."
        case .negativePromptUnsupportedOnEdit:
            return "negativePrompt is not wired on the edit surface (the branch that would "
                + "carry it is disabled at imgCfgScale 1); omit it or use textToImage."
        case .sizeNotTokenAligned(let w, let h, let m):
            return "width/height must be multiples of \(m) (got \(w)x\(h))."
        case .distilledTierCannotAnalyze:
            return "VQA needs the understanding stream of a base tier; use bf16 or 8bit."
        case .metaDataOutOfRange(let key, let value, let range):
            return "metaData \(key) = \(value) is outside \(range.lowerBound)...\(range.upperBound)."
        }
    }
}

@InferenceActor
public final class SenseNovaU1Package: ModelPackage {
    public typealias Configuration = SenseNovaU1Configuration

    public nonisolated static var manifest: PackageManifest {
        PackageManifest(
            license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .mit),
            provenance: Provenance(
                sourceRepo: "sensenova/SenseNova-U1.5-8B-MoT",
                revision: "07d76f61474b9c6e6999e22c559314d3439b8c81", tier: 3),
            requirements: RequirementsManifest(
                // Split footprints, 2048² envelope, M5 Max.
                //
                // int8 is RE-BASELINED from in-app `phys_footprint` (SenseNova
                // Demo, Engine pane): floor 19.97 GB measured post-load with the
                // MLX pool trimmed, worst peak 23.5 GB over a cold+warm pair ⇒
                // activation 3.53 GB. The previous split (19.5 / 5.0) was wrong
                // in BOTH directions at once — under-declaring the persistent
                // floor the governor reserves for the model's lifetime while
                // over-declaring the transient by 1.4×, which needlessly denies
                // co-residency to other models. The totals happened to match,
                // which is exactly why only the split shows the error.
                //
                // 2026-08-26: ALL FOUR tiers now measured headless, one process
                // per number (in-process residue makes back-to-back runs
                // unusable), with the pre-load baseline captured so `resident`
                // is weights and not process overhead — it measured 0.01 GB, so
                // floor IS weights here. bf16 and int4 were under-declared by
                // ~3.3% against the CLI-derived figures and are corrected:
                // bf16 35.17 GB measured (was 34.0), int4 11.87 (was 11.5).
                // int8 measured 19.98 against 20.5 declared — left alone, since
                // over-declaring resident is the safe direction.
                //
                // Activations are LEFT AS DECLARED. Measured T2I peaks at the
                // 2048² envelope are 2.93 / 3.35 / 2.52 GB, comfortably inside
                // 4.0 / 4.2 / 4.5 — but editing adds vision-token activation and
                // has NOT been measured, so the headroom stays until it is.
                footprints: [
                    QuantFootprint(
                        quant: .bf16, residentBytes: 35_500_000_000,
                        peakActivationBytes: 4_000_000_000),
                    QuantFootprint(
                        quant: .int8, residentBytes: 20_500_000_000,
                        peakActivationBytes: 4_200_000_000),
                    QuantFootprint(
                        quant: .int4, residentBytes: 12_200_000_000,
                        peakActivationBytes: 4_500_000_000),
                ],
                requiredBackends: [.metalGPU],
                os: OSRequirement(minMacOS: SemanticVersion(major: 26, minor: 0, patch: 0)),
                // Measured on M5 Max only so far; relax after receipts on
                // smaller chips (the int4 tier should fit Pro-class machines).
                chipFloor: .max
            ),
            specialties: [],
            surfaces: [
                T2IContract.descriptor(
                    name: "sensenova-u1",
                    summary: "SenseNova-U1.5-8B-MoT unified T2I (pixel-space rectified "
                        + "flow, no VAE): native 2048²-class buckets, text rendering, "
                        + "50-step base or cfg-free 8-step distill tiers. metaData: "
                        + "think=true for the reasoning mode (base tiers).",
                    modes: []
                ),
                IEditContract.descriptor(
                    name: "sensenova-u1-edit",
                    summary: "Identity-preserving instruction editing on the same "
                        + "resident model (image-conditioned generation, cfg 4; "
                        + "metaData imageGuidance (1...4) adds the image-CFG axis; "
                        + "base bf16/8bit tiers).",
                    modes: []
                ),
                ImageAnalysisContract.descriptor(
                    name: "sensenova-u1-vqa",
                    summary: "Visual question answering on the SAME resident model "
                        + "(understanding stream): grounded description, reading, and "
                        + "reasoning about an image. metaData: maxTokens, temperature. "
                        + "Base bf16/8bit tiers.",
                    modes: []
                ),
            ]
        )
    }

    private let configuration: Configuration
    private var model: NEOChatModel?
    private var tokenizer: SenseNovaTokenizer?

    /// metaData is caller-supplied and may arrive typed (native clients) or as
    /// strings (JSON tool-calling), so every reader accepts both.
    nonisolated static func number(
        _ metaData: MetaData, _ key: String, in range: ClosedRange<Double>
    ) throws -> Double? {
        let raw: Double?
        switch metaData[key] {
        case .double(let d): raw = d
        case .int(let i): raw = Double(i)
        case .string(let s): raw = Double(s)
        default: raw = nil
        }
        guard let value = raw else { return nil }
        guard range.contains(value) else {
            throw SenseNovaU1PackageError.metaDataOutOfRange(key: key, value: value, range: range)
        }
        return value
    }

    nonisolated static func flag(_ metaData: MetaData, _ key: String) -> Bool {
        switch metaData[key] {
        case .bool(let b): return b
        case .string(let s): return (s as NSString).boolValue
        case .int(let i): return i != 0
        default: return false
        }
    }

    public nonisolated init(configuration: Configuration) {
        self.configuration = configuration
    }

    public func load() async throws {
        guard model == nil else { return }
        // Engine-executed materialization (contract 1.24) fetches the declared
        // artifact before load(); this guard is the offline backstop.
        guard let snapshot = configuration.resolvedSnapshotDirectory(
            storeRoot: configuration.modelsRootDirectory),
            FileManager.default.fileExists(
                atPath: snapshot.appendingPathComponent("config.json").path)
        else {
            throw SenseNovaU1PackageError.unreadableSnapshot(
                configuration.snapshotPath.isEmpty
                    ? configuration.variant.repo : configuration.snapshotPath)
        }
        // Artifacts load with zero conversion transient (mmap + verified
        // update); the HF-checkpoint fallback path sanitizes at load.
        let model = WeightLoading.isArtifact(snapshot)
            ? try WeightLoading.loadArtifact(from: snapshot)
            : try WeightLoading.load(from: snapshot, dtype: .bfloat16)
        self.tokenizer = try await SenseNovaTokenizer.load(from: snapshot)
        self.model = model
    }

    public func unload() async {
        model = nil
        tokenizer = nil
        MLX.Memory.clearCache()  // release the retained MLX pool so eviction frees RSS
    }

    public func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        // CAN-1: entry checkpoint FIRST — before notLoaded validation. Mid-run
        // cadence lives in the core (per denoise step / per decoded token).
        try Task.checkCancellation()
        guard let model, let tokenizer else { throw PackageError.notLoaded }

        switch request.capability {
        case .textToImage:
            guard let t2i = request as? T2IRequest else {
                throw PackageError.unsupportedCapability(request.capability)
            }
            return try await runT2I(t2i, model: model, tokenizer: tokenizer)
        case .imageAnalysis:
            guard let analysis = request as? ImageAnalysisRequest else {
                throw PackageError.unsupportedCapability(request.capability)
            }
            guard !configuration.variant.isDistilled else {
                throw SenseNovaU1PackageError.distilledTierCannotAnalyze
            }
            return try await runAnalysis(analysis, model: model, tokenizer: tokenizer)
        case .imageEdit:
            guard let edit = request as? IEditRequest else {
                throw PackageError.unsupportedCapability(request.capability)
            }
            guard !configuration.variant.isDistilled else {
                throw SenseNovaU1PackageError.distilledTierCannotEdit
            }
            return try await runEdit(edit, model: model, tokenizer: tokenizer)
        default:
            throw PackageError.unsupportedCapability(request.capability)
        }
    }

    /// Contract 1.18: report at the same seams the CAN checkpoints sit on, so a
    /// consumer bound to `engine.runProgress` sees a live step counter instead of
    /// an indeterminate spinner for the length of a 2048² render.
    nonisolated static var denoiseReporter: (Int, Int) -> Void {
        { step, totalSteps in
            RunProgress.report(.denoise, step: step, totalSteps: totalSteps)
        }
    }

    // MARK: - T2I

    private func runT2I(
        _ request: T2IRequest, model: NEOChatModel, tokenizer: SenseNovaTokenizer
    ) async throws -> T2IResponse {
        let variant = configuration.variant
        var params = T2IParams()
        params.numSteps = request.steps ?? variant.defaultSteps
        params.cfgScale = request.guidanceScale.map(Float.init) ?? variant.defaultGuidance
        params.seed = request.seed ?? 0
        let width = request.width ?? 1024
        let height = request.height ?? 1024

        // token grid is 32 px; a non-multiple silently truncates via integer
        // division and would make the declared Image size a lie.
        let px = model.config.pixelsPerToken
        guard width % px == 0, height % px == 0 else {
            throw SenseNovaU1PackageError.sizeNotTokenAligned(
                width: width, height: height, multiple: px)
        }

        let think: Bool = {
            switch request.metaData["think"] {
            case .bool(let b): return b
            case .string(let raw): return (raw as NSString).boolValue
            default: return false
            }
        }()
        if think, variant.isDistilled {
            throw SenseNovaU1PackageError.distilledTierCannotThink
        }
        let image: MLXArray
        if think {
            let condThinkIds = tokenizer.encode(
                Conversation.buildPrompt(
                    userMessage: request.prompt,
                    systemMessage: Conversation.systemMessageForGen,
                    appendText: "<think>\n"))
            let uncond = params.cfgScale > 1
                ? tokenizer.encode(
                    Conversation.t2iUncondPrompt(negativePrompt: request.negativePrompt ?? ""))
                : nil
            let suffix = tokenizer.encode("\n\n" + Conversation.imgStartToken)
            var thinkTokens = 0
            (image, _) = try model.t2iGenerateThink(
                condThinkIds: condThinkIds, uncondIds: uncond, imgSuffixIds: suffix,
                width: width, height: height, params: params,
                onToken: { _ in
                    thinkTokens += 1
                    RunProgress.report(.generate, step: thinkTokens)
                },
                onStep: Self.denoiseReporter)
        } else {
            let (cond, uncond) = tokenizer.t2iIDs(
                prompt: request.prompt, negativePrompt: request.negativePrompt ?? "")
            image = try model.t2iGenerate(
                condIds: cond, uncondIds: params.cfgScale > 1 ? uncond : nil,
                width: width, height: height, params: params,
                onStep: Self.denoiseReporter)
        }
        try Task.checkCancellation()
        return T2IResponse(image: try Self.pngArtifact(image))
    }

    // MARK: - Edit

    private func runEdit(
        _ request: IEditRequest, model: NEOChatModel, tokenizer: SenseNovaTokenizer
    ) async throws -> IEditResponse {
        guard !request.images.isEmpty else { throw SenseNovaU1PackageError.imageDecode }
        if let negative = request.negativePrompt, !negative.isEmpty {
            throw SenseNovaU1PackageError.negativePromptUnsupportedOnEdit
        }
        let inputs = try request.images.map {
            try SenseNovaImageIO.loadEditImage(data: $0.data)
        }
        // Output size: explicit wins, else first input's aspect at ~2048² px
        // (reference `_resolve_output_size`).
        let px = model.config.pixelsPerToken
        let (width, height): (Int, Int)
        if let w = request.width, let h = request.height {
            guard w % px == 0, h % px == 0 else {
                throw SenseNovaU1PackageError.sizeNotTokenAligned(width: w, height: h, multiple: px)
            }
            (width, height) = (w, h)
        } else {
            let target = 2048 * 2048
            let (h, w) = SenseNovaImageIO.smartResize(
                height: inputs[0].gridH * 16, width: inputs[0].gridW * 16,
                factor: 32, minPixels: target, maxPixels: target)
            (width, height) = (w, h)
        }

        var params = T2IParams()
        params.numSteps = request.steps ?? 50
        params.cfgScale = request.guidanceScale.map(Float.init) ?? 4.0
        params.seed = request.seed ?? 0

        // The image-CFG axis (the reference's `img_cfg_scale`, the Space's
        // "Image Guidance"): at 1.0 the uncond branch is unused; above it the
        // three-branch combine needs an empty-prompt prefix too.
        let imgCfgScale = Float(
            try Self.number(request.metaData, "imageGuidance", in: 1.0...4.0) ?? 1.0)

        let counts = inputs.map(\.tokenCount)
        let condIds = try tokenizer.encode(
            Conversation.editCondPrompt(request.prompt, imageTokenCounts: counts))
        let imgCondIds = try tokenizer.encode(
            Conversation.editImgCondPrompt(imageTokenCounts: counts))
        let uncondIds: [Int32]? =
            imgCfgScale > 1
            ? tokenizer.encode(Conversation.t2iUncondPrompt()) : nil

        let image = try model.it2iGenerate(
            condIds: condIds, imgCondIds: imgCondIds, uncondIds: uncondIds,
            images: inputs, width: width, height: height,
            params: params, imgCfgScale: imgCfgScale,
            onStep: Self.denoiseReporter)
        try Task.checkCancellation()
        return IEditResponse(image: try Self.pngArtifact(image))
    }

    // MARK: - VQA

    private func runAnalysis(
        _ request: ImageAnalysisRequest, model: NEOChatModel, tokenizer: SenseNovaTokenizer
    ) async throws -> ImageAnalysisResponse {
        let image = try SenseNovaImageIO.loadEditImage(data: request.image.data)

        var sampling = SamplingParams()
        sampling.maxNewTokens = Int(
            try Self.number(request.metaData, "maxTokens", in: 1...4096) ?? 512)
        sampling.temperature = Float(
            try Self.number(request.metaData, "temperature", in: 0...2) ?? 0)
        sampling.seed = request.metaData["seed"].flatMap {
            if case .int(let i) = $0 { return UInt64(max(0, i)) }
            return nil
        } ?? 0

        let wantsReasoning = Self.flag(request.metaData, "think")
        let userMessage = try Conversation.expandImagePlaceholders(
            prompt: "<image>\n" + request.prompt, imageTokenCounts: [image.tokenCount])
        let ids = tokenizer.encode(
            Conversation.vqaPrompt(userMessage: userMessage, think: wantsReasoning))

        var produced = 0
        let answer = try model.chat(ids: ids, images: [image], params: sampling) { _ in
            produced += 1
            RunProgress.report(.generate, step: produced, totalSteps: sampling.maxNewTokens)
        }
        try Task.checkCancellation()
        // The canonical text is the ANSWER; a think block is never it. Callers
        // that want the deliberation ask for it (metaData includeReasoning).
        let (text, reasoning) = Conversation.splitReasoning(tokenizer.decode(answer))
        if Self.flag(request.metaData, "includeReasoning"), let reasoning {
            return ImageAnalysisResponse(text: "<think>\n\(reasoning)\n</think>\n\n\(text)")
        }
        return ImageAnalysisResponse(text: text)
    }

    // MARK: - output encoding (canonical PNG artifact, C3)

    /// (1, 3, H, W) tensor → the canonical `Image` artifact, with the declared
    /// dimensions taken from the TENSOR (never from the request, which may have
    /// been rounded down by the token grid).
    nonisolated static func pngArtifact(_ tensor: MLXArray) throws -> Image {
        Image(
            format: .png, data: try encodePNG(tensor),
            width: tensor.dim(3), height: tensor.dim(2))
    }

    /// (1, 3, H, W) generation-normalized tensor → PNG.
    nonisolated static func encodePNG(_ tensor: MLXArray) throws -> Data {
        let h = tensor.dim(2)
        let w = tensor.dim(3)
        let rgb01 = clip(tensor.asType(.float32) * 0.5 + 0.5, min: 0, max: 1)
        let hwc = rgb01[0].transposed(1, 2, 0)  // (H, W, 3)
        let bytes = MLX.round(hwc * 255).asType(.uint8).asArray(UInt8.self)

        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: cs,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw SenseNovaU1PackageError.pngEncode }
        let buf = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
        for i in 0 ..< (w * h) {
            buf[i * 4] = bytes[i * 3]
            buf[i * 4 + 1] = bytes[i * 3 + 1]
            buf[i * 4 + 2] = bytes[i * 3 + 2]
            buf[i * 4 + 3] = 255
        }
        guard let image = ctx.makeImage() else { throw SenseNovaU1PackageError.pngEncode }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.png.identifier as CFString, 1, nil)
        else { throw SenseNovaU1PackageError.pngEncode }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw SenseNovaU1PackageError.pngEncode
        }
        return out as Data
    }
}

extension SenseNovaU1Package {
    /// The author one-liner the engine registers.
    public nonisolated static var registration: PackageRegistration {
        .of(SenseNovaU1Package.self)
    }
}
