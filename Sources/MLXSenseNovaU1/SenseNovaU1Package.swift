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

    public var errorDescription: String? {
        switch self {
        case .unreadableSnapshot(let p): return "SenseNova artifact not readable at \(p)."
        case .imageDecode: return "Could not decode an input image."
        case .pngEncode: return "PNG encoding failed."
        case .distilledTierCannotEdit:
            return "The 8step distill tiers are T2I-only; use the bf16 or 8bit variant for imageEdit."
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
                // Split footprints measured on the OFFLINE ARTIFACTS (M5 Max,
                // sensenova-cli, 2048² envelope; artifact load has no
                // materialize-then-quantize transient, so peak ≈ resident):
                //   bf16 resident 33.4 GB, worst peak 35.1 → activation 1.7 GB
                //   int8 resident 19.0 GB, worst peak 22.9 → activation 3.9 GB
                //   int4 resident 11.2 GB, worst peak 14.8 → activation 3.6 GB
                // Declared with headroom. AB-R-0137 / PORTING-SPEC status.
                footprints: [
                    QuantFootprint(
                        quant: .bf16, residentBytes: 34_000_000_000,
                        peakActivationBytes: 4_000_000_000),
                    QuantFootprint(
                        quant: .int8, residentBytes: 19_500_000_000,
                        peakActivationBytes: 5_000_000_000),
                    QuantFootprint(
                        quant: .int4, residentBytes: 11_500_000_000,
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
                        + "resident model (image-conditioned generation, cfg 4 + "
                        + "image-cfg 1; base bf16/8bit tiers).",
                    modes: []
                ),
            ]
        )
    }

    private let configuration: Configuration
    private var model: NEOChatModel?
    private var tokenizer: SenseNovaTokenizer?

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

        let think = { if case .bool(true)? = request.metaData["think"] { return true }; return false }()
        let image: MLXArray
        if think, !variant.isDistilled {
            let condThinkIds = tokenizer.encode(
                Conversation.buildPrompt(
                    userMessage: request.prompt,
                    systemMessage: Conversation.systemMessageForGen,
                    appendText: "<think>\n"))
            let uncond = params.cfgScale > 1
                ? tokenizer.encode(Conversation.t2iUncondPrompt()) : nil
            let suffix = tokenizer.encode("\n\n" + Conversation.imgStartToken)
            (image, _) = try model.t2iGenerateThink(
                condThinkIds: condThinkIds, uncondIds: uncond, imgSuffixIds: suffix,
                width: width, height: height, params: params)
        } else {
            let (cond, uncond) = tokenizer.t2iIDs(prompt: request.prompt)
            image = try model.t2iGenerate(
                condIds: cond, uncondIds: params.cfgScale > 1 ? uncond : nil,
                width: width, height: height, params: params)
        }
        try Task.checkCancellation()
        let png = try Self.encodePNG(image)
        return T2IResponse(
            image: Image(format: .png, data: png, width: width, height: height))
    }

    // MARK: - Edit

    private func runEdit(
        _ request: IEditRequest, model: NEOChatModel, tokenizer: SenseNovaTokenizer
    ) async throws -> IEditResponse {
        guard !request.images.isEmpty else { throw SenseNovaU1PackageError.imageDecode }
        let inputs = try request.images.map {
            try SenseNovaImageIO.loadEditImage(data: $0.data)
        }
        // Output size: explicit wins, else first input's aspect at ~2048² px
        // (reference `_resolve_output_size`).
        let (width, height): (Int, Int)
        if let w = request.width, let h = request.height {
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

        let counts = inputs.map(\.tokenCount)
        let condIds = tokenizer.encode(
            Conversation.editCondPrompt(request.prompt, imageTokenCounts: counts))
        let imgCondIds = tokenizer.encode(
            Conversation.editImgCondPrompt(imageTokenCounts: counts))

        let image = try model.it2iGenerate(
            condIds: condIds, imgCondIds: imgCondIds, uncondIds: nil,
            images: inputs, width: width, height: height,
            params: params, imgCfgScale: 1.0)
        try Task.checkCancellation()
        let png = try Self.encodePNG(image)
        return IEditResponse(
            image: Image(format: .png, data: png, width: width, height: height))
    }

    // MARK: - output encoding (canonical PNG artifact, C3)

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
