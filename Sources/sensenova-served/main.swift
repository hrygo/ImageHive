// sensenova-served - resident SenseNova-U1.5 image service.
//
// Local addition (not upstream). One process owns the weights; clients talk to
// it over a unix-domain socket using newline-delimited JSON, the same framing
// MCP uses for stdio (MCP spec 2026-07-28, "Custom Transports").
//
// Responsibilities:
//   single instance  - socket bind is the mutex; a second process exits
//   single resident  - one tier loaded at a time, generations serialized
//   tier tolerant    - a requested tier that is not installed is served by the
//                      installed one, at that artifact's own recipe
//   idle unload      - TTL after last use, with a minimum warm time
//   observable       - loads_total / resident_tier / inflight / queue_depth
//
// Configuration: $SENSENOVA_HOME/config.json (see ServiceConfig below), with
// environment variables (SENSENOVA_HOME, SENSENOVA_CONFIG, SENSENOVA_TTL_SECONDS,
// SENSENOVA_MIN_WARM_SECONDS, SENSENOVA_SOCKET, SENSENOVA_MODELS, SENSENOVA_OUT,
// SENSENOVA_FAST_ARTIFACT, SENSENOVA_QUALITY_ARTIFACT) overriding it. Both are optional: with neither,
// the defaults below describe a stock `install.sh` layout.

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import MLX
import SenseNovaU1
import UniformTypeIdentifiers

let environmentForConfig = ProcessInfo.processInfo.environment

/// The socket protocol version: bumped only when the wire format changes in a way
/// an existing client would misread. Reported by `status` and `options`.
let protocolVersion = 1

/// The project version — `cli/lib/common.sh`'s `SV_VERSION`, which `install.sh`
/// writes into `service.conf`. Without the key (an install from before this key
/// existed, or a bare `swift run` in a checkout) this says `unknown` rather than a
/// number that belongs to nothing: it used to print `0.1.0`, which matched no
/// release, no commit and no tarball, so a run could not be traced back to a build.
func confValue(_ key: String, in path: String) -> String? {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    for line in text.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("\(key)=") else { continue }
        let raw = trimmed.dropFirst(key.count + 1)
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    }
    return nil
}

let userHomeEarly = environmentForConfig["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
let projectVersion = environmentForConfig["SENSENOVA_VERSION"]
    ?? confValue("SENSENOVA_VERSION", in: environmentForConfig["SENSENOVA_CONF"]
        ?? "\(environmentForConfig["SENSENOVA_HOME"] ?? "\(userHomeEarly)/Library/Application Support/SenseNovaU1")/service.conf")
    ?? "unknown"

if CommandLine.arguments.dropFirst().contains(where: { $0 == "--version" || $0 == "-v" }) {
    print("sensenova-served \(projectVersion) (socket protocol \(protocolVersion))")
    exit(0)
}

/// The knobs a user is allowed to turn, from $SENSENOVA_HOME/config.json:
///
///     {
///       "ttl_seconds": 600,
///       "min_warm_seconds": 60,
///       "fast_artifact": "SenseNova-U1.5-8B-MoT-8step-4bit",
///       "quality_artifact": "SenseNova-U1.5-8B-MoT-bf16",
///       "write_sidecar": true
///     }
///
/// Artifact paths are relative to SENSENOVA_MODELS unless absolute. The file is
/// optional, and environment variables win over it, so `install.sh` can drive
/// everything without writing one. Both tier keys are independent and optional:
/// name what you installed and the daemon serves the other tier from it
/// (`resolveTier`), which is what makes a single-artifact machine work.
struct ServiceConfig {
    var ttlSeconds: Double = 600
    var minWarmSeconds: Double = 60
    var fastArtifact = "SenseNova-U1.5-8B-MoT-8step-4bit"
    var qualityArtifact = "SenseNova-U1.5-8B-MoT-bf16"
    /// Write `<image>.png.json` next to every image; see the sidecar note in the
    /// validation section below. `null` means the built-in default (on).
    var writeSidecar: Bool?
    /// What is wrong with the file, in words a user can act on. A config.json that
    /// exists but cannot be used used to be indistinguishable from no file at all:
    /// settings were dropped with no trace anywhere, so the service quietly behaved
    /// differently from the way it was configured (measured 2026-09-18 — a truncated
    /// file, a type-wrong `ttl_seconds` and a 000-mode file all ran the defaults).
    /// Reported at startup, in `status` and therefore in `doctor`.
    var warnings: [String] = []

    static func load(from url: URL) -> ServiceConfig {
        var config = ServiceConfig()
        let path = url.path
        // Absent is the normal case (install.sh drives the settings through the
        // environment), so it is not worth a word. Present-but-broken is.
        guard FileManager.default.fileExists(atPath: path) else { return config }
        guard let data = FileManager.default.contents(atPath: path) else {
            config.warnings.append("\(path) cannot be read — serving the built-in defaults")
            return config
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            config.warnings.append("\(path) is not valid JSON ("
                + (error as NSError).localizedDescription + ") — every setting in it is ignored")
            return config
        }
        guard let object = parsed as? [String: Any] else {
            config.warnings.append("\(path) is not a JSON object — every setting in it is ignored")
            return config
        }

        func ignore(_ key: String, _ value: Any) {
            config.warnings.append("\(path): \(key) must be a number, a string or true/false, got "
                + "\(describeJSONValue(value)) — that key is ignored")
        }
        func number(_ key: String, _ apply: (Double) -> Void) {
            guard let raw = object[key], !(raw is NSNull) else { return }
            // Not `raw is Bool`: a ttl of 1 or 0 would read as a boolean and be
            // dropped (see jsonIsBoolean).
            if jsonIsBoolean(raw) { ignore(key, raw); return }
            if let n = raw as? NSNumber { apply(n.doubleValue); return }
            ignore(key, raw)
        }
        func text(_ key: String, _ apply: (String) -> Void) {
            guard let raw = object[key], !(raw is NSNull) else { return }
            guard let value = raw as? String, !value.isEmpty else { ignore(key, raw); return }
            apply(value)
        }

        number("ttl_seconds") { config.ttlSeconds = $0 }
        number("min_warm_seconds") { config.minWarmSeconds = $0 }
        text("fast_artifact") { config.fastArtifact = $0 }
        text("quality_artifact") { config.qualityArtifact = $0 }
        if let raw = object["write_sidecar"], !(raw is NSNull) {
            if jsonIsBoolean(raw), let flag = raw as? Bool { config.writeSidecar = flag }
            else { ignore("write_sidecar", raw) }
        }
        return config
    }
}

// $HOME first, then the passwd entry: the shell CLI and the installers all use
// $HOME, so honouring it here keeps a sandboxed or overridden HOME consistent
// instead of silently reaching back into the real user's app home.
let userHome = userHomeEarly
let home = URL(fileURLWithPath: environmentForConfig["SENSENOVA_HOME"]
    ?? "\(userHome)/Library/Application Support/SenseNovaU1")
let modelsRoot = URL(fileURLWithPath: environmentForConfig["SENSENOVA_MODELS"]
    ?? home.appendingPathComponent("models").path)
let configURL = URL(fileURLWithPath: environmentForConfig["SENSENOVA_CONFIG"]
    ?? home.appendingPathComponent("config.json").path)
let serviceConfig = ServiceConfig.load(from: configURL)
let ttlSeconds = environmentForConfig["SENSENOVA_TTL_SECONDS"].flatMap(Double.init) ?? serviceConfig.ttlSeconds
let minWarmSeconds = environmentForConfig["SENSENOVA_MIN_WARM_SECONDS"].flatMap(Double.init) ?? serviceConfig.minWarmSeconds
let fastArtifact = environmentForConfig["SENSENOVA_FAST_ARTIFACT"] ?? serviceConfig.fastArtifact
let qualityArtifact = environmentForConfig["SENSENOVA_QUALITY_ARTIFACT"] ?? serviceConfig.qualityArtifact
let socketPath = environmentForConfig["SENSENOVA_SOCKET"]
    ?? home.appendingPathComponent("served.sock").path
let outDir = URL(fileURLWithPath: environmentForConfig["SENSENOVA_OUT"]
    ?? "\(userHome)/Pictures/SenseNovaU1")

func artifactDir(_ tier: String) -> URL {
    let relative: String
    switch tier {
    case "fast", "8step", "fast8": relative = fastArtifact
    default: relative = qualityArtifact
    }
    if relative.hasPrefix("/") { return URL(fileURLWithPath: relative) }
    return modelsRoot.appendingPathComponent(relative)
}

/// The tiers a request can name. `fast` is the distilled 8-step path, `quality`
/// the 50-step reference path; an unrecognised name means `quality`, exactly as
/// in `artifactDir` above.
let tierNames = ["fast", "quality"]

func canonicalTier(_ tier: String) -> String {
    ["fast", "8step", "fast8"].contains(tier) ? "fast" : "quality"
}

func otherTier(_ tier: String) -> String {
    canonicalTier(tier) == "fast" ? "quality" : "fast"
}

/// An artifact is usable when it is complete enough to load: `config.json` for
/// the architecture and `tokenizer.json` for the prompt plumbing.
func artifactReady(_ tier: String) -> Bool {
    let dir = artifactDir(tier)
    return FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path)
        && FileManager.default.fileExists(atPath: dir.appendingPathComponent("tokenizer.json").path)
}

/// Which artifact actually answers a request for `tier`.
///
/// Tier is a preference, not a requirement: installers offer a lightweight tier
/// and a quality tier, and a machine that installed only one of them must still
/// serve every request, so the installed artifact takes over when the requested
/// one is not on disk. The *recipe* follows the artifact that runs (see
/// `generate`), never the request, so distilled weights are never driven with
/// the 50-step reference recipe and the bf16 weights are never run at 8 steps
/// with cfg 1.0.
func resolveTier(_ tier: String) -> String {
    let wanted = canonicalTier(tier)
    if artifactReady(wanted) { return wanted }
    let fallback = otherTier(wanted)
    return artifactReady(fallback) ? fallback : wanted
}

// MARK: - request validation

/// Everything a client can get wrong is answered with an ordinary error result
/// *before* the weights are touched. This is not politeness:
///
///  * The denoise loop derives its latent grid as `pixels / 32` and reshapes the
///    pixel tensor back to `grid * 32` (32 = `Configuration.pixelsPerToken`,
///    `patchSize / downsampleRatio` = 16 / 0.5), so a size that is not a multiple of 32
///    makes the two disagree and MLX calls `fatalError` — measured on 1000x1000:
///    `Fatal error: [reshape] Cannot reshape array of size 3000000 into shape
///    (1,3,31,32,31,32)`. A fatal error cannot be caught, so the whole **daemon**
///    dies: the client sees an empty response, and every other client of the shared
///    service loses its resident model with it. Refusing up front is the only way
///    to keep one malformed request from taking the service down.
///  * A negative seed traps the same way (`UInt64(-1)`), and `steps = 0` walks the
///    loop zero times and hands back an un-denoised tensor.
///
/// The same checks run for a raw socket client as for the MCP front end, so the
/// rules hold no matter what is on the other end of the socket.
enum RequestError {
    static func bad(_ message: String) -> NSError {
        NSError(domain: "sensenova", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Whether a value that came out of JSON is actually a boolean.
///
/// Swift's own `is Bool` cannot answer this: JSON numbers arrive as `__NSCFNumber`
/// and *any* number that happens to be 0 or 1 also casts to `Bool` (measured
/// 2026-09-18 — `1 is Bool` is true, `2 is Bool` is false). Using it as the guard in
/// the strict readers below rejected `"seed": 1` and `"steps": 1` as booleans, which
/// the smoke test caught. Only CoreFoundation distinguishes `__NSCFBoolean` from a
/// number that merely looks like one.
func jsonIsBoolean(_ value: Any) -> Bool {
    guard let number = value as? NSNumber else { return false }
    return CFGetTypeID(number) == CFBooleanGetTypeID()
}

/// What the caller sent, in words that can be acted on.
func describeJSONValue(_ value: Any) -> String {
    if jsonIsBoolean(value), let flag = value as? Bool { return "the boolean \(flag)" }
    switch value {
    case let text as String:
        return "the string \"\(text.count > 40 ? String(text.prefix(40)) + "…" : text)\""
    case let list as [Any]: return "an array of \(list.count)"
    case is [String: Any]: return "an object"
    case let number as NSNumber: return "the number \(number)"
    default: return "a \(type(of: value))"
    }
}

// The readers below are the ones the model-backed commands use. A key that is
// *present but the wrong type* is an error, never a silent fallback: a caller that
// sends `"width": "512"` used to get 1024x1024, `"steps": "4"` used to get 50, and
// `"seed": "126"` used to get a **random** seed — the same class of silent
// divergence as the `negative` argument that was dropped for months. Absent still
// means "use the default".
func intArgStrict(_ request: [String: Any], _ key: String) throws -> Int? {
    guard let raw = request[key] else { return nil }
    if jsonIsBoolean(raw) { throw RequestError.bad("\(key) must be a number, got \(describeJSONValue(raw))") }
    if let n = raw as? Int { return n }
    if let d = raw as? Double {
        guard d == d.rounded() else {
            throw RequestError.bad("\(key) must be a whole number, got \(d)")
        }
        return Int(d)
    }
    if let n = raw as? NSNumber { return n.intValue }
    throw RequestError.bad("\(key) must be a number, got \(describeJSONValue(raw))")
}

func doubleArgStrict(_ request: [String: Any], _ key: String) throws -> Double? {
    guard let raw = request[key] else { return nil }
    if jsonIsBoolean(raw) { throw RequestError.bad("\(key) must be a number, got \(describeJSONValue(raw))") }
    if let d = raw as? Double { return d }
    if let n = raw as? Int { return Double(n) }
    if let n = raw as? NSNumber { return n.doubleValue }
    throw RequestError.bad("\(key) must be a number, got \(describeJSONValue(raw))")
}

func stringArgStrict(_ request: [String: Any], _ key: String) throws -> String? {
    guard let raw = request[key], !(raw is NSNull) else { return nil }
    guard let text = raw as? String else {
        throw RequestError.bad("\(key) must be a string, got \(describeJSONValue(raw))")
    }
    return text
}

func boolArgStrict(_ request: [String: Any], _ key: String) throws -> Bool? {
    guard let raw = request[key] else { return nil }
    guard jsonIsBoolean(raw), let flag = raw as? Bool else {
        throw RequestError.bad("\(key) must be true or false, got \(describeJSONValue(raw))")
    }
    return flag
}

func stringListArgStrict(_ request: [String: Any], _ key: String) throws -> [String]? {
    guard let raw = request[key] else { return nil }
    guard let list = raw as? [String] else {
        throw RequestError.bad("\(key) must be an array of paths, got \(describeJSONValue(raw))")
    }
    return list
}

/// The tier, accepted only under the names this service defines.
func tierArg(_ request: [String: Any]) throws -> String? {
    guard let raw = request["tier"] else { return nil }
    guard let name = raw as? String else {
        throw RequestError.bad("tier must be a string (fast or quality), got \(describeJSONValue(raw))")
    }
    guard ["fast", "quality", "8step", "fast8"].contains(name) else {
        throw RequestError.bad("tier \"\(name)\" is not a tier; use fast or quality")
    }
    return name
}

/// Decodes reference images for a request, naming the path that failed. No model is
/// involved, so callers do this *before* `ensureLoaded`: a request that cannot run
/// must not pull 33 GiB of weights in first.
func loadReferenceImages(_ paths: [String]) throws -> [EditImage] {
    guard !paths.isEmpty else { throw RequestError.bad("images[] is required") }
    return try paths.map { path in
        guard FileManager.default.fileExists(atPath: path) else {
            throw RequestError.bad("no such image: \(path)")
        }
        do {
            return try SenseNovaImageIO.loadEditImage(url: URL(fileURLWithPath: path))
        } catch {
            throw RequestError.bad("could not decode \(path): "
                + (error as NSError).localizedDescription)
        }
    }
}

/// A pixel dimension the model can actually render.
func validatedSize(_ value: Int, _ axis: String) throws -> Int {
    guard value > 0 else { throw RequestError.bad("\(axis) \(value) must be positive") }
    guard value <= 4096 else {
        throw RequestError.bad("\(axis) \(value) is above the supported maximum of 4096 pixels")
    }
    guard value % 32 == 0 else {
        let down = (value / 32) * 32
        let up = down + 32
        let nearest = value - down <= up - value ? down : up
        throw RequestError.bad("""
        \(axis) \(value) is not a multiple of 32 — the latent grid is \(axis)/32, so \(value) \
        would be reshaped to \(down) and MLX would abort the whole service (an uncatchable fatal \
        error, not a failed request). Use \(nearest).
        """)
    }
    return value
}

/// Validates an optional integer argument up front; `nil` means "use the default",
/// which may depend on the artifact that ends up resident and is therefore resolved
/// later. Rejecting a nonsense value here avoids loading 33 GiB to find out.
func validatedOptionalInt(_ request: [String: Any], _ key: String,
                          range: ClosedRange<Int>) throws -> Int? {
    guard let value = try intArgStrict(request, key) else { return nil }
    guard range.contains(value) else {
        throw RequestError.bad("\(key) \(value) is outside the supported range "
            + "\(range.lowerBound)...\(range.upperBound)")
    }
    return value
}

/// The seed, plus whether the caller pinned it — a sidecar that says "random" is
/// how a run repeated from scratch is told apart from one that merely looks alike.
func validatedSeed(_ request: [String: Any]) throws -> (seed: UInt64, explicit: Bool) {
    guard let raw = try intArgStrict(request, "seed") else {
        return (UInt64(Int.random(in: 1...2_000_000)), false)
    }
    guard raw >= 0 else {
        throw RequestError.bad("seed \(raw) is negative — seeds are unsigned integers (0...\(Int.max))")
    }
    return (UInt64(raw), true)
}

// MARK: - status snapshot

/// A lock-protected copy of everything `status` reports, published by the actor
/// whenever its state changes.
///
/// It exists because the `Core` actor is **not** re-entrant across the generation
/// call: `t2iGenerate` is one long synchronous call, so while a job runs the actor's
/// executor is held and any other request queues behind it. Measured: a `status`
/// request issued during a 1536x1024 job came back after 75.3 s — the length of the
/// generation — so `model_status`, the tool an agent uses to ask "are you busy?",
/// answered only once the answer had stopped mattering, and `unload`'s "busy" reply
/// could not be observed at all. Read-only commands now answer from this snapshot on
/// the connection thread, without touching the actor.
final class StatusBoard: @unchecked Sendable {
    private let lock = NSLock()
    private var state: [String: Any] = [:]

    func publish(_ values: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        for (key, value) in values { state[key] = value }
    }

    func clear(_ key: String) {
        lock.lock(); state.removeValue(forKey: key); lock.unlock()
    }

    func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return state
    }
}

let statusBoard = StatusBoard()

// MARK: - live progress

/// Step counter for the job in flight, so `status` can answer "step 23 of 50,
/// 18.4s in" instead of just "busy". The denoise callback runs on another thread,
/// hence the lock. Opt-in progress *messages* on the socket were deliberately not
/// added: a client that reads one line per request (the documented two-line
/// integration) would misparse them.
final class JobProgress: @unchecked Sendable {
    private let lock = NSLock()
    /// Mirrors every change into `status`; a job can run for a minute, and the board
    /// is the only thing a client can read while the actor is busy.
    private let board: StatusBoard
    private var tool: String?
    private var step = 0
    private var total = 0
    private var startedAt: Date?

    init(board: StatusBoard) { self.board = board }

    func begin(_ tool: String, total: Int) {
        lock.lock(); defer { lock.unlock() }
        self.tool = tool
        self.step = 0
        self.total = total
        self.startedAt = Date()
        board.publish(["current": currentLocked() ?? [:]])
    }

    func advance(_ step: Int) {
        lock.lock(); self.step = step; lock.unlock()
        if let current = snapshot() { board.publish(["current": current]) }
    }

    func end() {
        lock.lock(); defer { lock.unlock() }
        tool = nil
        step = 0
        total = 0
        startedAt = nil
        board.clear("current")
    }

    func snapshot() -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        return currentLocked()
    }

    private func currentLocked() -> [String: Any]? {
        guard let tool, let startedAt else { return nil }
        var out: [String: Any] = [
            "tool": tool,
            "step": step,
            "total": total,
            "elapsed_seconds": (Date().timeIntervalSince(startedAt) * 10).rounded() / 10,
        ]
        if total > 0 { out["percent"] = Int((Double(step) / Double(total) * 100).rounded()) }
        return out
    }
}

let jobProgress = JobProgress(board: statusBoard)

/// The capability report. Static facts plus what this machine has, so a client can
/// stop discovering the rules by firing requests and reading the rejections — and,
/// before the size check existed, the answer to a size the model cannot render was
/// the daemon dying.
func optionsReport() -> [String: Any] {
    let resident = statusBoard.snapshot()["resident_tier"] as? String ?? "cold"
    var available: [String] = []
    for tier in tierNames where artifactReady(tier) { available.append(tier) }
    return ["ok": true, "options": [
        "protocol": protocolVersion,
        "project_version": projectVersion,
        "commands": ["generate", "edit", "vqa", "status", "options", "unload"],
        "sizes": [
            "rule": "width and height must be multiples of 32 (pixelsPerToken = patchSize / downsampleRatio = 16 / 0.5)",
            "minimum": 32,
            "maximum": 4096,
            "recommended": [
                ["label": "square 1:1", "width": 1024, "height": 1024],
                ["label": "landscape 3:2", "width": 1216, "height": 832],
                ["label": "landscape 16:9", "width": 1600, "height": 896],
                ["label": "portrait 9:16", "width": 896, "height": 1600],
            ],
            "note": "bigger is slower; 1024x1024 is the reference point for comparisons",
        ],
        "steps": [
            "minimum": 1, "maximum": 500,
            "fast_default": 8, "quality_default": 50,
            "note": "omit to use the recipe of the artifact that runs; a value of 12 or less also selects the fast tier when tier is omitted",
        ],
        "cfg": [
            "fast_default": 1.0, "quality_default": 4.0,
            "note": "1.0 or below skips the unconditional branch, so negative is ignored at that setting",
        ],
        "seed": [
            "type": "unsigned integer",
            "note": "same seed, same artifact, same settings = byte-identical PNG (measured)",
            "default": "random in 1...2000000, recorded in the sidecar and in the file name",
        ],
        "negative_prompt": [
            "generate": true,
            "edit": false,
            "note": "generate only: the edit surface has no unconditional branch, so edit_image rejects a non-empty negative instead of ignoring it",
        ],
        "sidecar": [
            "enabled": sidecarEnabled,
            "path": "<image>.png.json",
            "fields": "prompt + sha256, negative, seed + whether it was pinned, width, height, steps, cfg, tier, artifact, seconds, peak memory, project version",
        ],
        "cancellation": [
            "supported": false,
            "note": "a dispatched request runs to completion and its PNG lands even if the client goes away; there is no cancel command",
        ],
        "tiers": [
            "available": available,
            "resident": resident,
            "note": "a requested tier that is not installed is served by the installed one, at that artifact's own recipe",
        ],
        "output_dir": outDir.path,
    ]]
}

/// Commands answered without entering the actor. `unload` is included only for its
/// "busy" case: unloading for real needs the actor, so when nothing is running this
/// returns nil and the request goes the normal way.
func immediateAnswer(_ request: [String: Any]) -> [String: Any]? {
    switch (request["cmd"] as? String) ?? "" {
    case "status":
        return ["ok": true, "status": statusBoard.snapshot()]
    case "options":
        return optionsReport()
    case "unload":
        if let inflight = statusBoard.snapshot()["inflight"] as? Int, inflight > 0 {
            return ["ok": false, "error": "busy"]
        }
        return nil
    default:
        return nil
    }
}

// MARK: - sidecar metadata

/// Every image gets a `<name>.png.json` beside it carrying the prompt verbatim and
/// its SHA-256, the seed and whether it was pinned, the size, the steps and cfg that
/// actually ran, the artifact that produced it, the wall time and the project
/// version. Without it two runs cannot be told apart afterwards: the file name
/// carries only the tier and the seed, and the log carries neither the prompt nor
/// the cfg, so "same prompt, same seed, different model" — the comparison this
/// service exists to make possible — could only be asserted from memory.
///
/// `"write_sidecar": false` in config.json (or `SENSENOVA_SIDECAR=0`) turns it off.
let sidecarEnabled = (environmentForConfig["SENSENOVA_SIDECAR"].map { $0 != "0" })
    ?? (serviceConfig.writeSidecar ?? true)

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func sha256Hex(file path: String) -> String? {
    (try? Data(contentsOf: URL(fileURLWithPath: path))).map(sha256Hex)
}

@discardableResult
func writeSidecar(for image: URL, fields: [String: Any]) -> URL? {
    guard sidecarEnabled else { return nil }
    var payload = fields
    payload["image"] = image.lastPathComponent
    payload["created_at"] = ISO8601DateFormatter().string(from: Date())
    payload["project_version"] = projectVersion
    payload["protocol"] = protocolVersion
    guard let data = try? JSONSerialization.data(
        withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return nil }
    let url = image.appendingPathExtension("json")
    do {
        try data.write(to: url)
        return url
    } catch {
        log("could not write \(url.path): \(error)")
        return nil
    }
}

// MARK: - PNG output (NCHW float32 in -1..1 -> 8-bit RGB PNG)

enum OutputError: Error { case badShape([Int]), encodeFailed(String) }

func writePNG(_ image: MLXArray, to url: URL) throws {
    var x = image.asType(.float32)
    if x.ndim == 4 { x = x.squeezed(axis: 0) }
    guard x.ndim == 3, x.dim(0) == 3 else { throw OutputError.badShape(x.shape) }
    let height = x.dim(1)
    let width = x.dim(2)
    let planes = x.asArray(Float.self)
    var rgba = [UInt8](repeating: 255, count: width * height * 4)
    for i in 0..<(width * height) {
        for c in 0..<3 {
            let v = planes[c * height * width + i] * 0.5 + 0.5
            rgba[i * 4 + c] = UInt8(max(0, min(255, Int((v * 255).rounded()))))
        }
    }
    guard let provider = CGDataProvider(data: Data(rgba) as CFData),
          let cg = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw OutputError.encodeFailed(url.lastPathComponent) }
    CGImageDestinationAddImage(dest, cg, nil)
    guard CGImageDestinationFinalize(dest) else { throw OutputError.encodeFailed(url.lastPathComponent) }
}

// MARK: - the single owner of the weights

/// The resident weights. MLX model objects are reference types that do not
/// declare `Sendable`; the load task materializes them and hands them over
/// once, after which only the actor touches them. `@unchecked` records exactly
/// that hand-off instead of leaving a Swift 6 error for later.
struct Resident: @unchecked Sendable {
    let model: NEOChatModel
    let tokenizer: SenseNovaTokenizer
    /// The tier actually in memory, which is not always the one the request
    /// named: a machine with a single artifact serves both tiers from it. The
    /// generation recipe is read from here, so a fallback cannot mix the two.
    let tier: String
}

actor Core {
    private var model: NEOChatModel?
    private var tokenizer: SenseNovaTokenizer?
    private var residentTier: String?
    private var loadedAt: Date?
    private var lastUseAt: Date?
    private var loadsTotal = 0
    private var inflight = 0
    private var waiting = 0
    private var lastPeakMB = 0
    /// In-flight load, so concurrent callers await the same materialization
    /// instead of each starting their own (the actor is re-entrant at awaits).
    private var pendingLoad: (tier: String, task: Task<Resident, Error>)?

    /// Publishes the current state to `statusBoard` and returns it. Called on every
    /// transition — job start and finish, load, unload, idle unload — so the
    /// read-only fast path in `immediateAnswer` is never stale.
    @discardableResult
    func publish() -> [String: Any] {
        var available: [String] = []
        for tier in tierNames where artifactReady(tier) { available.append(tier) }
        var out: [String: Any] = [
            "resident_tier": residentTier ?? "cold",
            "available_tiers": available,
            "loads_total": loadsTotal,
            "inflight": inflight,
            "queue_depth": waiting,
            "ttl_seconds": ttlSeconds,
            "min_warm_seconds": minWarmSeconds,
            "last_peak_mb": lastPeakMB,
            "protocol": protocolVersion,
            "project_version": projectVersion,
            // Which process is answering. The daemon is normally started by an MCP
            // front end rather than by launchd, so a reinstall can leave an older
            // binary serving the socket while the launchd job exits 3 without ever
            // binding; without the pid there is no way to tell from the outside.
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
        ]
        // Settings the daemon could not read: visible without opening the log, and
        // `doctor` reads the same field.
        if !serviceConfig.warnings.isEmpty { out["config_warnings"] = serviceConfig.warnings }
        if let d = lastUseAt { out["last_request_at"] = ISO8601DateFormatter().string(from: d) }
        if let d = loadedAt { out["loaded_at"] = ISO8601DateFormatter().string(from: d) }
        statusBoard.publish(out)
        if let current = jobProgress.snapshot() { statusBoard.publish(["current": current]) }
        else { statusBoard.clear("current") }
        return statusBoard.snapshot()
    }

    /// In-actor view of the same state.
    func status() -> [String: Any] { publish() }

    private func release() {
        model = nil
        tokenizer = nil
        residentTier = nil
        loadedAt = nil
        MLX.Memory.clearCache()
        publish()
    }

    func unload() -> [String: Any] {
        guard pendingLoad == nil else { return ["ok": false, "error": "load in progress"] }
        let tier = residentTier
        release()
        return ["ok": true, "unloaded": tier ?? "none", "resident_tier": "cold"]
    }

    /// TTL sweep: drop resident weights once idle past TTL. Never evicts while a
    /// generation is in flight or before the minimum warm time has elapsed.
    func tick(now: Date = Date()) {
        guard inflight == 0, model != nil, pendingLoad == nil else { return }
        let idle = now.timeIntervalSince(lastUseAt ?? now)
        let warm = now.timeIntervalSince(loadedAt ?? now)
        if idle >= ttlSeconds, warm >= minWarmSeconds {
            log("idle \(Int(idle))s >= ttl, unloading \(residentTier ?? "?")")
            release()
        }
    }

    private func ensureLoaded(_ requested: String) async throws -> Resident {
        let wanted = canonicalTier(requested)
        let tier = resolveTier(wanted)
        if tier != wanted {
            log("asked for '\(wanted)' but that artifact is not installed — serving from '\(tier)'")
        }
        if let m = model, let t = tokenizer, residentTier == tier {
            return Resident(model: m, tokenizer: t, tier: tier)
        }
        if let pending = pendingLoad {
            if pending.tier == tier { return try await pending.task.value }
            throw NSError(domain: "sensenova", code: 4, userInfo: [NSLocalizedDescriptionKey:
                "busy loading tier '\(pending.tier)'; retry once it settles"])
        }
        if model != nil { release() }
        let dir = artifactDir(tier)
        guard artifactReady(tier) else {
            throw NSError(domain: "sensenova", code: 2, userInfo: [
                NSLocalizedDescriptionKey: """
                no model artifact installed: looked for \(artifactDir(wanted).path) and \
                \(artifactDir(otherTier(wanted)).path) — download one with \
                `sensenova-u1 models pull fast-4bit` (lightweight, 11 GiB) or \
                `sensenova-u1 models pull quality-bf16` (33 GiB), or point \
                \(configURL.path) at an artifact you built
                """])
        }
        let t0 = Date()
        let task = Task.detached(priority: .userInitiated) { () throws -> Resident in
            let m = try WeightLoading.loadArtifact(from: dir)
            let t = try await SenseNovaTokenizer.load(from: dir)
            return Resident(model: m, tokenizer: t, tier: tier)
        }
        pendingLoad = (tier, task)
        let resident: Resident
        do {
            resident = try await task.value
        } catch {
            pendingLoad = nil
            throw error
        }
        model = resident.model
        tokenizer = resident.tokenizer
        residentTier = tier
        loadedAt = Date()
        lastUseAt = Date()
        loadsTotal += 1
        pendingLoad = nil
        publish()
        log("loaded \(tier) in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s (loads_total=\(loadsTotal))")
        return resident
    }

    func handle(_ request: [String: Any]) async -> [String: Any] {
        let cmd = (request["cmd"] as? String) ?? ""
        if cmd == "status" { return ["ok": true, "status": status()] }
        if cmd == "options" { return optionsReport() }
        if cmd == "unload" {
            guard inflight == 0 else { return ["ok": false, "error": "busy"] }
            return unload()
        }
        guard cmd == "generate" || cmd == "edit" || cmd == "vqa" else {
            return ["ok": false, "error": "unknown cmd '\(cmd)'"]
        }

        // A malformed request is answered before anything is loaded, so a caller that
        // gets the JSON type wrong hears about it instead of silently receiving the
        // default behaviour (see intArgStrict).
        let distilledFloor: Int
        let requestedTier: String?
        do {
            distilledFloor = try intArgStrict(request, "steps") ?? 50
            requestedTier = try tierArg(request)
        } catch {
            return ["ok": false, "error": (error as NSError).localizedDescription]
        }
        let tier = requestedTier
            ?? (cmd == "generate" && distilledFloor <= 12 ? "fast" : "quality")
        waiting += 1
        inflight += 1
        lastUseAt = Date()
        publish()
        defer {
            waiting = max(0, waiting - 1)
            inflight = max(0, inflight - 1)
            lastUseAt = Date()
            lastPeakMB = MLX.Memory.peakMemory / (1 << 20)
            publish()
        }
        do {
            switch cmd {
            case "generate": return try await generate(request, tier: tier)
            case "edit": return try await edit(request, tier: tier)
            default: return try await vqa(request, tier: tier)
            }
        } catch {
            // localizedDescription, not the NSError dump: this text is what the client
            // shows the user, and "Error Domain=... Code=1 UserInfo={...}" is not part
            // of the message.
            return ["ok": false, "error": (error as NSError).localizedDescription]
        }
    }

    private func promptPair(_ tok: SenseNovaTokenizer, _ prompt: String, _ negative: String,
                            cfg: Float) -> ([Int32], [Int32]?) {
        // The negative prompt *is* the unconditional branch of CFG on this
        // architecture, so it is passed into the uncond encoding rather than being a
        // separate knob. It only has an effect when cfg > 1, which is the quality
        // recipe; the fast recipe runs cfg 1.0 and therefore has no uncond branch.
        let pair = tok.t2iIDs(prompt: prompt, negativePrompt: negative)
        return (pair.cond, cfg > 1 ? pair.uncond : nil)
    }

    private func generate(_ request: [String: Any], tier: String) async throws -> [String: Any] {
        // Validate before ensureLoaded: a request that cannot run must not pull 33 GiB
        // of weights in first.
        let prompt = try stringArgStrict(request, "prompt") ?? ""
        guard !prompt.isEmpty else { throw RequestError.bad("prompt is required") }
        let width = try validatedSize(try intArgStrict(request, "width") ?? 1024, "width")
        let height = try validatedSize(try intArgStrict(request, "height") ?? 1024, "height")
        let stepsArg = try validatedOptionalInt(request, "steps", range: 1...500)
        let (seed, seedExplicit) = try validatedSeed(request)
        let negative = try stringArgStrict(request, "negative") ?? ""
        let wanted = canonicalTier(tier)
        let resident = try await ensureLoaded(wanted)
        let m = resident.model
        let tok = resident.tokenizer
        // The recipe belongs to the artifact in memory, not to the request: a
        // request the installed artifact cannot honour is served at that
        // artifact's own settings instead of being driven out of distribution.
        let distilled = resident.tier == "fast"
        var p = T2IParams()
        p.numSteps = stepsArg ?? (distilled ? 8 : 50)
        p.cfgScale = Float(try doubleArgStrict(request, "cfg") ?? (distilled ? 1.0 : 4.0))
        p.seed = seed
        let (cond, uncond) = promptPair(tok, prompt, negative, cfg: p.cfgScale)
        let t0 = Date()
        jobProgress.begin("generate", total: p.numSteps)
        defer { jobProgress.end() }
        let image = try m.t2iGenerate(
            condIds: cond, uncondIds: uncond, width: width, height: height, params: p,
            onStep: { step, _ in jobProgress.advance(step) })
        eval(image)
        let seconds = Date().timeIntervalSince(t0)
        let url = try writeOutput(image, tag: distilled ? "fast\(p.numSteps)" : "t2i", seed: p.seed)
        var out: [String: Any] = [
            "ok": true, "path": url.path, "tier": resident.tier, "seed": Int(p.seed),
            "seed_source": seedExplicit ? "explicit" : "random",
            "steps": p.numSteps, "cfg": Double(p.cfgScale), "width": width, "height": height,
            "seconds": (seconds * 100).rounded() / 100, "peak_mb": MLX.Memory.peakMemory / (1 << 20),
        ]
        if resident.tier != wanted { out["tier_requested"] = wanted }
        if !negative.isEmpty { out["negative"] = negative }
        if let sidecar = writeSidecar(for: url, fields: sidecarFields(
            tool: "generate_image", prompt: prompt, negative: negative, seed: p.seed,
            seedExplicit: seedExplicit, width: width, height: height, steps: p.numSteps,
            cfg: Double(p.cfgScale), resident: resident, wanted: wanted, seconds: seconds)) {
            out["metadata"] = sidecar.path
        }
        return out
    }

    /// The shared sidecar payload. `seconds` is rounded the same way the response
    /// rounds it, so the two records agree.
    private func sidecarFields(tool: String, prompt: String, negative: String, seed: UInt64,
                               seedExplicit: Bool, width: Int, height: Int, steps: Int, cfg: Double,
                               resident: Resident, wanted: String, seconds: TimeInterval,
                               extra: [String: Any] = [:]) -> [String: Any] {
        let dir = artifactDir(resident.tier)
        var fields: [String: Any] = [
            "tool": tool,
            "prompt": prompt,
            "prompt_sha256": sha256Hex(Data(prompt.utf8)),
            "negative": negative,
            "negative_sha256": sha256Hex(Data(negative.utf8)),
            "seed": Int(seed),
            "seed_source": seedExplicit ? "explicit" : "random",
            "width": width,
            "height": height,
            "steps": steps,
            "cfg": cfg,
            "tier": resident.tier,
            "tier_requested": wanted,
            "artifact": dir.lastPathComponent,
            "model_dir": dir.path,
            "seconds": (seconds * 100).rounded() / 100,
            "peak_mb": MLX.Memory.peakMemory / (1 << 20),
        ]
        for (key, value) in extra { fields[key] = value }
        return fields
    }

    private func loadReferences(_ request: [String: Any]) throws -> [EditImage] {
        try loadReferenceImages(try stringListArgStrict(request, "images") ?? [])
    }

    private func edit(_ request: [String: Any], tier: String) async throws -> [String: Any] {
        let prompt = try stringArgStrict(request, "prompt") ?? ""
        guard !prompt.isEmpty else { throw RequestError.bad("prompt is required") }
        if let negative = try stringArgStrict(request, "negative"), !negative.isEmpty {
            throw RequestError.bad("""
            negative is not supported on edit_image: the edit surface has no unconditional branch, \
            so it would be silently ignored (the model package rejects it for the same reason). \
            Say what must change and what must stay inside prompt.
            """)
        }
        let stepsArg = try validatedOptionalInt(request, "steps", range: 1...500)
        let (seed, seedExplicit) = try validatedSeed(request)
        var widthArg = try intArgStrict(request, "width") ?? 0
        var heightArg = try intArgStrict(request, "height") ?? 0
        if widthArg != 0 { widthArg = try validatedSize(widthArg, "width") }
        if heightArg != 0 { heightArg = try validatedSize(heightArg, "height") }
        let targetPixels = try intArgStrict(request, "target_pixels") ?? (2048 * 2048)
        guard targetPixels > 0 else {
            throw RequestError.bad("target_pixels \(targetPixels) must be positive")
        }
        // Before ensureLoaded for the same reason as the sizes: a bad path is not worth
        // a 33 GiB load, and decoding needs no weights.
        let images = try loadReferences(request)
        let wanted = canonicalTier(tier)
        let resident = try await ensureLoaded(wanted)
        let m = resident.model
        let tok = resident.tokenizer
        var p = T2IParams()
        p.numSteps = stepsArg ?? 50
        p.cfgScale = Float(try doubleArgStrict(request, "cfg") ?? 4.0)
        p.seed = seed
        let counts = images.map(\.tokenCount)
        var width = widthArg
        var height = heightArg
        if width == 0 || height == 0 {
            let (h, w) = SenseNovaImageIO.smartResize(
                height: images[0].gridH * 16, width: images[0].gridW * 16, factor: 32,
                minPixels: targetPixels, maxPixels: targetPixels)
            width = w
            height = h
        }
        let condIds = try tok.encode(Conversation.editCondPrompt(prompt, imageTokenCounts: counts))
        let imgCondIds = try tok.encode(Conversation.editImgCondPrompt(imageTokenCounts: counts))
        let t0 = Date()
        jobProgress.begin("edit", total: p.numSteps)
        defer { jobProgress.end() }
        let image = try m.it2iGenerate(
            condIds: condIds, imgCondIds: imgCondIds, uncondIds: nil, images: images,
            width: width, height: height, params: p,
            imgCfgScale: Float(try doubleArgStrict(request, "img_cfg") ?? 1.0),
            onStep: { step, _ in jobProgress.advance(step) })
        eval(image)
        let seconds = Date().timeIntervalSince(t0)
        let url = try writeOutput(image, tag: "edit", seed: p.seed)
        var out: [String: Any] = [
            "ok": true, "path": url.path, "tier": resident.tier, "seed": Int(p.seed),
            "seed_source": seedExplicit ? "explicit" : "random",
            "steps": p.numSteps, "cfg": Double(p.cfgScale), "width": width, "height": height,
            "seconds": (seconds * 100).rounded() / 100, "peak_mb": MLX.Memory.peakMemory / (1 << 20),
        ]
        if resident.tier != wanted { out["tier_requested"] = wanted }
        // The reference images and their hashes belong in the record too: an edit is
        // only reproducible together with the exact input it started from.
        let references: [[String: Any]] = zip((request["images"] as? [String] ?? []), images).map { path, image in
            var entry: [String: Any] = ["path": path, "sha256": sha256Hex(file: path) ?? ""]
            entry["pixels"] = "\(image.gridW * 16)x\(image.gridH * 16)"
            return entry
        }
        if let sidecar = writeSidecar(for: url, fields: sidecarFields(
            tool: "edit_image", prompt: prompt, negative: "", seed: p.seed,
            seedExplicit: seedExplicit, width: width, height: height, steps: p.numSteps,
            cfg: Double(p.cfgScale), resident: resident, wanted: wanted, seconds: seconds,
            extra: ["img_cfg": try doubleArgStrict(request, "img_cfg") ?? 1.0,
                    "source_images": references])) {
            out["metadata"] = sidecar.path
        }
        return out
    }

    private func vqa(_ request: [String: Any], tier: String) async throws -> [String: Any] {
        let question = try stringArgStrict(request, "prompt") ?? ""
        let paths = try stringListArgStrict(request, "images") ?? []
        let think = try boolArgStrict(request, "think") ?? false
        let maxTokens = try intArgStrict(request, "max_tokens") ?? 512
        guard maxTokens >= 1, maxTokens <= 8192 else {
            throw RequestError.bad("max_tokens \(maxTokens) is outside the supported range 1...8192")
        }
        // Every path has to load. This used to be a `compactMap { try? … }`, so a
        // mistyped path was dropped and the model answered about nothing at all —
        // an empty question and no images is not a request, it is an accident.
        var images: [EditImage] = []
        if !paths.isEmpty { images = try loadReferenceImages(paths) }
        guard !images.isEmpty || !question.isEmpty else {
            throw RequestError.bad("images[] is required (or send a prompt and no images for a text answer)")
        }
        let wanted = canonicalTier(tier)
        let resident = try await ensureLoaded(wanted)
        let m = resident.model
        let tok = resident.tokenizer
        var message = question
        if !images.isEmpty {
            message = try Conversation.expandImagePlaceholders(
                prompt: String(repeating: "<image>\n", count: images.count) + question,
                imageTokenCounts: images.map(\.tokenCount))
        }
        let ids = tok.encode(Conversation.vqaPrompt(
            userMessage: message, think: think))
        var sampling = SamplingParams()
        sampling.maxNewTokens = maxTokens
        let t0 = Date()
        let answer = try m.chat(ids: ids, images: images, params: sampling)
        let seconds = Date().timeIntervalSince(t0)
        let (text, reasoning) = Conversation.splitReasoning(tok.decode(answer))
        var out: [String: Any] = [
            "ok": true, "text": text, "tier": resident.tier,
            "seconds": (seconds * 100).rounded() / 100, "peak_mb": MLX.Memory.peakMemory / (1 << 20),
        ]
        if resident.tier != wanted { out["tier_requested"] = wanted }
        if let reasoning { out["reasoning"] = reasoning }
        return out
    }

    private func writeOutput(_ image: MLXArray, tag: String, seed: UInt64) throws -> URL {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
        let url = outDir.appendingPathComponent("\(stamp)-\(tag)-seed\(seed).png")
        try writePNG(image, to: url)
        return url
    }
}

// MARK: - helpers and socket plumbing

func log(_ message: String) {
    FileHandle.standardError.write("sensenova-served: \(message)\n".data(using: .utf8)!)
}

@discardableResult
func withSockaddr(_ path: String, _ body: (UnsafePointer<sockaddr>) -> Int32) -> Int32 {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        let chars = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
        _ = path.withCString { strncpy(chars, $0, 103) }
    }
    return withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0) }
    }
}

func openListener(_ path: String) -> Int32? {
    // sun_path is 104 bytes on macOS, including the terminating NUL. This used to
    // be truncated silently with strncpy, which produced a daemon listening on a
    // name nobody else could compute — or, after a restart, a bare exit 3 with
    // nothing in the log. Refusing up front turns a mystery into an instruction.
    guard path.utf8.count < 104 else {
        log("socket path is too long: \(path.utf8.count) bytes, macOS allows 103 (sun_path)")
        log("set SENSENOVA_SOCKET to a shorter path, or move SENSENOVA_HOME somewhere shorter")
        return nil
    }
    if FileManager.default.fileExists(atPath: path) {
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        let connected = withSockaddr(path) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        close(probe)
        if connected == 0 {
            log("another instance is live at \(path)")
            return nil
        }
        unlink(path)
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        log("socket() failed: \(String(cString: strerror(errno)))")
        return nil
    }
    let bound = withSockaddr(path) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    guard bound == 0, listen(fd, 16) == 0 else {
        log("could not bind \(path): \(String(cString: strerror(errno)))")
        close(fd)
        return nil
    }
    return fd
}

let core = Core()
// Seed the status snapshot before the socket opens, so the very first `status` gets
// a real answer instead of an empty object. Deliberately not top-level `await`: that
// would make this whole file an async context, and the `RunLoop.main.run()` that
// parks the daemon at the end is unavailable from one.
do {
    let seeded = DispatchSemaphore(value: 0)
    Task { await core.publish(); seeded.signal() }
    seeded.wait()
}
signal(SIGPIPE, SIG_IGN)
// A daemon killed by SIGTERM used to leave its socket file behind, and every
// readiness check in the CLI and the installer is "does the socket exist" — so a
// stop/restart could be followed by a check that succeeded against a socket nobody
// was listening on, and the install then failed its own smoke test while the daemon
// it had just started was still binding (measured 2026-09-18). Unlink on the way
// out. `unlink` and `write` are async-signal-safe; nothing in the handler allocates,
// so both strings are prepared as C buffers here, once, while the process is healthy:
// `unlink(someSwiftString)` bridges to a temporary C string, which allocates, and a
// signal handler must not allocate — the allocator may be mid-update when the signal
// arrives. `strdup` is the last allocation these handlers ever need.
let terminationNotice = strdup("sensenova-served: terminated by signal — socket removed\n")!
let socketPathForSignal = strdup(socketPath)!
for signalNumber in [SIGTERM, SIGINT] {
    signal(signalNumber) { _ in
        _ = unlink(socketPathForSignal)
        _ = write(STDERR_FILENO, terminationNotice, strlen(terminationNotice))
        _exit(0)
    }
}
try? FileManager.default.createDirectory(
    at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
    withIntermediateDirectories: true)

guard let listenFD = openListener(socketPath) else { exit(3) }
// Before the "listening" line, so the reason a setting did not take effect is in
// the log ahead of the evidence that the daemon came up anyway.
for warning in serviceConfig.warnings { log(warning) }
log("sensenova-served \(projectVersion) listening on \(socketPath) "
    + "(ttl \(Int(ttlSeconds))s, min warm \(Int(minWarmSeconds))s)")
log("home \(home.path)")
for tier in tierNames {
    log("  tier \(tier): \(artifactDir(tier).path)\(artifactReady(tier) ? "" : " [not installed]")")
}

let sweeper = Thread {
    while true {
        Thread.sleep(forTimeInterval: 5)
        Task { await core.tick() }
    }
}
sweeper.stackSize = 1 << 20
sweeper.start()

/// One client connection: a blocking read loop on its own thread, responses
/// written back through a serial queue so ordering stays intact.
final class Connection {
    private let fd: Int32
    private let writeQueue = DispatchQueue(label: "sensenova.write")
    private let core: Core

    init(fd: Int32, core: Core) {
        self.fd = fd
        self.core = core
    }

    func start() {
        // Borrowed into locals so the closures below need no implicit `self`.
        let fd = self.fd
        let core = self.core
        let writeQueue = self.writeQueue
        let thread = Thread {
            // One JSON object per line, and the answer is written in the same shape.
            func send(_ data: Data) {
                writeQueue.sync {
                    var out = data
                    out.append(0x0A)
                    out.withUnsafeBytes { raw in
                        var offset = 0
                        while offset < raw.count {
                            let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                            if written <= 0 { return }
                            offset += written
                        }
                    }
                }
            }
            func sendError(_ message: String) {
                let payload = ["ok": false, "error": message] as [String: Any]
                if let data = try? JSONSerialization.data(withJSONObject: payload) { send(data) }
            }
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = read(fd, &chunk, chunk.count)
                if n <= 0 {
                    // A client that sends a request without the terminating newline and
                    // then closes used to vanish silently; say so in the log, because
                    // the client is waiting for an answer that is never coming.
                    if !buffer.isEmpty {
                        log("client disconnected with \(buffer.count) bytes and no trailing newline "
                            + "(the protocol is one JSON object per line)")
                    }
                    break
                }
                buffer.append(contentsOf: chunk[0..<n])
                if buffer.count > 16 * 1024 * 1024, !buffer.contains(0x0A) {
                    log("dropping a client that sent \(buffer.count) bytes with no newline")
                    sendError("request line is longer than 16 MiB — send one JSON object per line")
                    break
                }
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: buffer.startIndex..<newline)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if line.isEmpty {
                        // A bare newline is not a request. Answering it keeps a client
                        // (or a shell) that sends one from waiting forever.
                        sendError("empty request — send one JSON object per line")
                        continue
                    }
                    Task {
                        let request = ((try? JSONSerialization.jsonObject(with: line)) as? [String: Any]) ?? [:]
                        // `status`, `options` and a busy `unload` are answered here, on
                        // the connection thread: during a generation the actor is held by
                        // the model call and would not reply until it finished (see
                        // StatusBoard). Everything that needs the model goes through it.
                        let response: [String: Any]
                        if let quick = immediateAnswer(request) {
                            response = quick
                        } else {
                            response = await core.handle(request)
                        }
                        guard let data = try? JSONSerialization.data(withJSONObject: response) else { return }
                        send(data)
                    }
                }
            }
            close(fd)
        }
        thread.stackSize = 1 << 20
        thread.start()
    }
}

let acceptThread = Thread {
    while true {
        let client = accept(listenFD, nil, nil)
        if client < 0 {
            if errno == EINTR { continue }
            Thread.sleep(forTimeInterval: 0.2)
            continue
        }
        Connection(fd: client, core: core).start()
    }
}
acceptThread.stackSize = 1 << 20
acceptThread.start()
RunLoop.main.run()
