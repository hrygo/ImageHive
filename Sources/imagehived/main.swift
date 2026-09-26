// imagehived - the resident daemon behind imagehive: one copy of the weights,
// one socket, every client served from it.
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
//   observable       - loads_total / resident_tier / inflight / queue_depth /
//                        jobs_total / jobs_failed / uptime_seconds
//
// Configuration: $IMAGEHIVE_HOME/config.json (see ServiceConfig below), with
// environment variables (IMAGEHIVE_HOME, IMAGEHIVE_CONFIG, IMAGEHIVE_TTL_SECONDS,
// IMAGEHIVE_MIN_WARM_SECONDS, IMAGEHIVE_SOCKET, IMAGEHIVE_MODELS, IMAGEHIVE_OUT,
// IMAGEHIVE_FAST_ARTIFACT, IMAGEHIVE_QUALITY_ARTIFACT) overriding it. Both are optional: with neither,
// the defaults below describe a stock `install.sh` layout.

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import MLX
import SenseNovaU1
import UniformTypeIdentifiers

let environmentForConfig = ProcessInfo.processInfo.environment

/// Leaves descriptors 0, 1 and 2 open, whatever the caller did to them, before this
/// process opens anything of its own. A daemon started with `2>&-` (a wrapper that
/// closes stderr, `imagehived 2>&1 | head`, a launchd job with a broken log path) used
/// to have its *listening socket* land on descriptor 2 — the first free one — so every
/// `log()` line was written into a descriptor that belonged to somebody else. The
/// measured 2026-09-19 shape of that bug in the front end: the line
/// `imagehive-mcp: ignoring notification …` went down the daemon socket, the daemon
/// answered `unknown cmd ''`, and the caller received that answer to its *next* call.
/// A log channel we do not own is `/dev/null`, never a socket, a PNG or a client.
func reserveStandardDescriptors() {
    for descriptor in Int32(0)...2 where fcntl(descriptor, F_GETFD) == -1 {
        let opened = open("/dev/null", O_RDWR)
        guard opened >= 0 else { continue }
        if opened != descriptor {
            _ = dup2(opened, descriptor)
            close(opened)
        }
    }
}

reserveStandardDescriptors()

/// The socket protocol version: bumped only when the wire format changes in a way
/// an existing client would misread. Reported by `status` and `options`.
let protocolVersion = 1

/// The project version — `cli/lib/common.sh`'s `IH_VERSION`, which `install.sh`
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
let projectVersion = environmentForConfig["IMAGEHIVE_VERSION"]
    ?? confValue("IMAGEHIVE_VERSION", in: environmentForConfig["IMAGEHIVE_CONF"]
        ?? "\(environmentForConfig["IMAGEHIVE_HOME"] ?? "\(userHomeEarly)/Library/Application Support/ImageHive")/service.conf")
    ?? "unknown"

if CommandLine.arguments.dropFirst().contains(where: { $0 == "--version" || $0 == "-v" }) {
    print("imagehived \(projectVersion) (socket protocol \(protocolVersion))")
    exit(0)
}

// Fold stdout into the log. The daemon's own records go to stderr; stdout is left to
// the libraries under it, and mlx-c's default error handler is
// `printf("MLX error: %s\n", …); exit(-1)` — it names the reason for a hard exit and
// then quits. Callers that keep both descriptors on one file (the launchd job and the
// MCP front end) already collect it, but the ones that capture only stderr — every
// test script, `verify_release.sh` — lose it, which is how a daemon that exited 255
// mid-request came back as `(closed, no reply)` with an empty log (measured
// 2026-09-18, the red CI run this line was written for). `--version` above still
// answers on the real stdout, which a caller may be reading.
dup2(STDERR_FILENO, STDOUT_FILENO)

/// The knobs a user is allowed to turn, from $IMAGEHIVE_HOME/config.json:
///
///     {
///       "ttl_seconds": 600,
///       "min_warm_seconds": 60,
///       "fast_artifact": "SenseNova-U1.5-8B-MoT-8step-4bit",
///       "quality_artifact": "SenseNova-U1.5-8B-MoT-bf16",
///       "write_sidecar": true
///     }
///
/// Artifact paths are relative to IMAGEHIVE_MODELS unless absolute. The file is
/// optional, and environment variables win over it, so `install.sh` can drive
/// everything without writing one. Both tier keys are independent and optional:
/// name what you installed and the daemon serves the other tier from it
/// (`resolveTier`), which is what makes a single-artifact machine work.
struct ServiceConfig {
    var ttlSeconds: Double = 600
    var minWarmSeconds: Double = 60
    /// How long a model request waits for its turn before it is refused. The
    /// daemon serializes generations, so a second request queues behind the
    /// first; without a ceiling a leaked client could wait out its whole
    /// deadline in silence.
    var queueTimeoutSeconds: Double = 300
    /// Idle seconds after the last request before the daemon drops the MLX buffer
    /// cache but keeps the weights. Burst use (several images, then a pause, then
    /// nothing for hours) leaves transient tensors and buffer pools behind; sweeping
    /// them early returns gigabytes while the next image still starts with no load.
    /// Full unload stays on `ttlSeconds`.
    var cacheTtlSeconds: Double = 120
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
        number("queue_timeout_seconds") { config.queueTimeoutSeconds = $0 }
        number("cache_ttl_seconds") { config.cacheTtlSeconds = $0 }
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
let home = URL(fileURLWithPath: environmentForConfig["IMAGEHIVE_HOME"]
    ?? "\(userHome)/Library/Application Support/ImageHive")
let modelsRoot = URL(fileURLWithPath: environmentForConfig["IMAGEHIVE_MODELS"]
    ?? home.appendingPathComponent("models").path)
let configURL = URL(fileURLWithPath: environmentForConfig["IMAGEHIVE_CONFIG"]
    ?? home.appendingPathComponent("config.json").path)
let serviceConfig = ServiceConfig.load(from: configURL)
let ttlSeconds = environmentForConfig["IMAGEHIVE_TTL_SECONDS"].flatMap(Double.init) ?? serviceConfig.ttlSeconds
let minWarmSeconds = environmentForConfig["IMAGEHIVE_MIN_WARM_SECONDS"].flatMap(Double.init) ?? serviceConfig.minWarmSeconds
let queueTimeoutSeconds = environmentForConfig["IMAGEHIVE_QUEUE_TIMEOUT_SECONDS"].flatMap(Double.init) ?? serviceConfig.queueTimeoutSeconds
let cacheTtlSeconds = environmentForConfig["IMAGEHIVE_CACHE_TTL_SECONDS"].flatMap(Double.init) ?? serviceConfig.cacheTtlSeconds
let fastArtifact = environmentForConfig["IMAGEHIVE_FAST_ARTIFACT"] ?? serviceConfig.fastArtifact
let qualityArtifact = environmentForConfig["IMAGEHIVE_QUALITY_ARTIFACT"] ?? serviceConfig.qualityArtifact
let socketPath = environmentForConfig["IMAGEHIVE_SOCKET"]
    ?? home.appendingPathComponent("imagehived.sock").path
let outDir = URL(fileURLWithPath: environmentForConfig["IMAGEHIVE_OUT"]
    ?? "\(userHome)/Pictures/ImageHive")

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
        NSError(domain: "imagehive", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
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

/// The largest whole number JSON can carry exactly: 2^53. Past it a double no longer
/// names one integer and one only, so "the caller sent this number" stops being true.
let exactJSONIntegerLimit = 9_007_199_254_740_992.0

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
        guard d.isFinite, d == d.rounded() else {
            throw RequestError.bad("\(key) must be a whole number, got \(d)")
        }
        // `Int(d)` is not a conversion here, it is a trap: a value outside Int's range
        // is a fatal error Swift cannot catch, and the whole daemon disappears with
        // SIGTRAP and an empty log. Measured 2026-09-19 — `"width": 1e30`,
        // `"steps": 1e19` and `"width": 9223372036854775808` each took the service
        // down on the spot, from a request that was supposed to be refused. Same rule
        // as the `[reshape]` fatal: refuse before it can reach anything.
        guard d.magnitude <= exactJSONIntegerLimit else {
            throw RequestError.bad("""
            \(key) \(d) is too large to be an exact whole number — JSON keeps numbers above \
            \(Int64(exactJSONIntegerLimit)) only approximately. Send a smaller integer, \
            written without an exponent.
            """)
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

/// The guidance scales `generate` and `edit` accept, and the range `options` reports.
/// Reported as a contract, not enforced as a taste: the reference recipe runs cfg 4.0
/// and the distilled one 1.0, and 100 is far past anything the model can use. The
/// bound exists because a value like `1e30` is still finite in JSON but becomes
/// `Float.inf`, and `inf` guidance produces NaN latents — which used to reach the PNG
/// writer and trap there (`Int(NaN)`) *after* a full generation, killing the shared
/// service minutes into somebody's session (measured 2026-09-19).
let guidanceLimits: ClosedRange<Double> = 0...100

/// Validated up front, resolved later: the default (1.0 or 4.0) depends on the
/// artifact that ends up resident, but a value the model cannot use must be refused
/// before the 33 GiB load.
func validatedGuidance(_ request: [String: Any], _ key: String) throws -> Float? {
    guard let value = try doubleArgStrict(request, key) else { return nil }
    guard value.isFinite, guidanceLimits.contains(value) else {
        throw RequestError.bad("\(key) \(value) is outside the supported range "
            + "\(Int(guidanceLimits.lowerBound))...\(Int(guidanceLimits.upperBound)) "
            + "(fast default 1.0, quality default 4.0)")
    }
    return Float(value)
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

/// Finished model jobs, split by outcome. Refusals that never reach the model
/// (bad args, unknown cmd) are not jobs and do not count here — these numbers
/// answer "how much work has this daemon done, and how much of it failed".
/// Lives outside the actor behind a lock (like StatusBoard): a queued waiter
/// cancelled while the actor is busy running a generation must still be counted
/// now, not once the actor drains.
final class JobCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    private var failed = 0
    private var cancelled = 0

    func noteFinished(failed: Bool) {
        lock.lock(); defer { lock.unlock() }
        total += 1
        if failed { self.failed += 1 }
    }
    func noteCancelled() {
        lock.lock(); defer { lock.unlock() }
        cancelled += 1
    }
    func snapshot() -> (total: Int, failed: Int, cancelled: Int) {
        lock.lock(); defer { lock.unlock() }
        return (total, failed, cancelled)
    }
}

let jobCounters = JobCounters()

/// When this process started, so `status` can report uptime without the actor.
let bootedAt = Date()

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
    private var token: String?
    private var step = 0
    private var total = 0
    private var startedAt: Date?

    init(board: StatusBoard) { self.board = board }

    func begin(_ tool: String, total: Int, token: String) {
        lock.lock(); defer { lock.unlock() }
        self.tool = tool
        self.token = token
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
        token = nil
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
        if let token { out["token"] = token }
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
        "commands": ["generate", "edit", "vqa", "status", "options", "unload", "cancel"],
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
            "minimum": Int(guidanceLimits.lowerBound), "maximum": Int(guidanceLimits.upperBound),
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
        "job_token": [
            "note": "every model request carries a token (client-supplied, or generated) for cancel; the running job's token is in status.current.token",
        ],
        "sidecar": [
            "enabled": sidecarEnabled,
            "path": "<image>.png.json",
            "fields": "prompt + sha256, negative, seed + whether it was pinned, width, height, steps, cfg, tier, artifact, seconds, peak memory, project version",
        ],
        "cancellation": [
            "supported": true,
            "cancel": ["cmd": "cancel", "token": "the token of a running job (status.current.token)"],
            "queue_timeout_seconds": queueTimeoutSeconds,
            "note": "a job ends at its next denoise-step boundary when cancelled or when its client disconnects; it writes no PNG and counts as cancelled, not failed. A waiter cancelled or disconnected while still queued counts as cancelled the same way. A job that waits longer than queue_timeout_seconds for its turn is refused before it starts.",
        ],
        "idle_reclamation": [
            "cache_ttl_seconds": cacheTtlSeconds,
            "ttl_seconds": ttlSeconds,
            "min_warm_seconds": minWarmSeconds,
            "note": "two tiers: past cache_ttl_seconds the daemon drops the MLX buffer cache but keeps the weights (burst pauses stay warm); past ttl_seconds it unloads everything. A failed job sweeps the cache the same way, without unloading.",
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
        // The snapshot is refreshed by the actor on every transition, but a long
        // idle stretch leaves it stale — `uptime_seconds` especially, which moves
        // even when nothing else does. Refresh the clock-driven fields here, on the
        // connection thread, without touching the actor (and without MLX: no
        // counters here may initialize Metal, see `mlxTouched`).
        var snap = statusBoard.snapshot()
        snap["uptime_seconds"] = Int(Date().timeIntervalSince(bootedAt))
        return ["ok": true, "status": snap]
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
/// `"write_sidecar": false` in config.json (or `IMAGEHIVE_SIDECAR=0`) turns it off.
let sidecarEnabled = (environmentForConfig["IMAGEHIVE_SIDECAR"].map { $0 != "0" })
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
            var v = planes[c * height * width + i] * 0.5 + 0.5
            // A NaN or an infinity here means the model produced a value no image can
            // hold — not a reason to lose the whole run. `Int(NaN)` traps, so the daemon
            // used to die *after* a full generation (measured 2026-09-19, reachable
            // through a guidance scale of `inf`); paint it as the extreme it is nearest.
            if !v.isFinite { v = v > 0 ? 1 : 0 }
            v = min(max(v, 0), 1)
            rgba[i * 4 + c] = UInt8((v * 255).rounded())
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
    /// When the idle cache sweep last ran (nil = never). Reported in status so
    /// `imagehive status` shows the two-tier reclamation is working, not just
    /// that the weights are still resident.
    private var lastCacheSweepAt: Date?
    /// Whether this process has initialized MLX (Metal) yet.
    ///
    /// MLX builds its Metal device on the *first* call, wherever that call comes
    /// from, and on a machine with no Metal device that first call cannot be
    /// survived: mlx-c's default error handler prints "MLX error: …" to stdout and
    /// then `exit(-1)`. So the two MLX calls this actor makes outside the model code
    /// (the peak-memory counter and `release()`'s `clearCache`) are gated on it: a
    /// request refused before `ensureLoaded` must leave the GPU stack untouched on a
    /// machine that cannot run the model at all (measured 2026-09-18 on a CI runner:
    /// no Metal device, and the first request to reach that counter — a `generate`
    /// refused for `"width": "512"` — exited the daemon with 255 instead of being
    /// answered).
    private var mlxTouched = false
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
            "jobs_total": jobCounters.snapshot().total,
            "jobs_failed": jobCounters.snapshot().failed,
            "jobs_cancelled": jobCounters.snapshot().cancelled,
            "uptime_seconds": Int(Date().timeIntervalSince(bootedAt)),
            "queue_timeout_seconds": queueTimeoutSeconds,
            "cache_ttl_seconds": cacheTtlSeconds,
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
        if let d = lastCacheSweepAt { out["last_cache_sweep_at"] = ISO8601DateFormatter().string(from: d) }
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
        // Same gate as the counters: `imagehive unload` on a cold daemon reaches this
        // line, and clearing a cache that cannot have anything in it is not worth
        // initializing Metal for.
        if mlxTouched { MLX.Memory.clearCache() }
        publish()
    }

    func unload() -> [String: Any] {
        guard pendingLoad == nil else { return ["ok": false, "error": "load in progress"] }
        let tier = residentTier
        release()
        return ["ok": true, "unloaded": tier ?? "none", "resident_tier": "cold"]
    }

    /// First tier of idle reclamation: drop the MLX buffer cache (transient
    /// tensors, buffer pools) but keep the weights, so the next image in a burst
    /// still starts with no load. Same `mlxTouched` gate as `release()`: sweeping
    /// a cache that cannot have anything in it must not initialize Metal.
    private func sweepCache() {
        guard mlxTouched else { return }
        MLX.Memory.clearCache()
        lastCacheSweepAt = Date()
        if mlxTouched { lastPeakMB = MLX.Memory.peakMemory / (1 << 20) }
        publish()
    }

    /// Idle sweeps, two tiers. Past `cache_ttl_seconds` the daemon drops the MLX
    /// buffer cache but keeps the weights (burst pauses stay warm); past
    /// `ttl_seconds` it unloads everything (long idle frees the gigabytes).
    /// Neither runs while a generation is in flight, while a load is pending, or
    /// before the minimum warm time has elapsed.
    func tick(now: Date = Date()) {
        guard inflight == 0, model != nil, pendingLoad == nil else { return }
        let idle = now.timeIntervalSince(lastUseAt ?? now)
        let warm = now.timeIntervalSince(loadedAt ?? now)
        guard warm >= minWarmSeconds else { return }
        if idle >= ttlSeconds {
            log("idle \(Int(idle))s >= ttl, unloading \(residentTier ?? "?")")
            release()
            return
        }
        // Re-sweep at most once per cache TTL: without the second clause every
        // 5s tick past the TTL would clear a cache the next request is about to
        // refill, churning for nothing.
        if idle >= cacheTtlSeconds {
            if let swept = lastCacheSweepAt {
                if now.timeIntervalSince(swept) >= cacheTtlSeconds {
                    log("idle \(Int(idle))s >= cache ttl, sweeping MLX cache (weights stay resident)")
                    sweepCache()
                }
            } else {
                log("idle \(Int(idle))s >= cache ttl, sweeping MLX cache (weights stay resident)")
                sweepCache()
            }
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
            throw NSError(domain: "imagehive", code: 4, userInfo: [NSLocalizedDescriptionKey:
                "busy loading tier '\(pending.tier)'; retry once it settles"])
        }
        if model != nil { release() }
        let dir = artifactDir(tier)
        guard artifactReady(tier) else {
            throw NSError(domain: "imagehive", code: 2, userInfo: [
                NSLocalizedDescriptionKey: """
                no model artifact installed: looked for \(artifactDir(wanted).path) and \
                \(artifactDir(otherTier(wanted)).path) — download one with \
                `imagehive models pull fast-4bit` (lightweight, 11 GiB) or \
                `imagehive models pull quality-bf16` (33 GiB), or point \
                \(configURL.path) at an artifact you built
                """])
        }
        let t0 = Date()
        // Past the guards: this is where the process starts touching MLX, so record
        // it before the load rather than after — a load that fails halfway still
        // leaves the stack initialized (and would otherwise die a second time in the
        // counters below).
        mlxTouched = true
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
            // A load that fails halfway leaves partially materialized arrays in
            // the MLX cache; drop them now instead of letting the next load or
            // generation inherit them.
            sweepCache()
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
        // Every model job carries a token so it can be cancelled by name. The
        // connection thread generated one when the request arrived (see
        // Connection.start); a client-supplied `token` wins, but like every
        // other key it is strictly typed — present-but-wrong is an error.
        let token: String
        do {
            token = try stringArgStrict(request, "token") ?? UUID().uuidString
        } catch {
            return ["ok": false, "error": (error as NSError).localizedDescription]
        }
        // A waiter can be cancelled after the connection thread's pre-handle
        // check but before the actor starts running it. Cancellation is not a
        // model failure: count it exactly like a queued disconnect and return
        // without touching the model or entering the inflight/waiting window.
        if Task.isCancelled {
            jobCounters.noteCancelled()
            return ["ok": false, "error": "cancelled", "cancelled": true, "token": token]
        }
        // Second half of the queue-timeout gate. The connection thread only
        // forwards when `inflight == 0`, but two waiters can both see zero and
        // enter one after the other — the loser finds `inflight > 0` here and
        // must re-check its own waiting time instead of queueing unboundedly
        // behind the winner inside the actor.
        if inflight > 0 {
            let queuedAt = (request["queued_at"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970
            let waited = Date().timeIntervalSince1970 - queuedAt
            if waited > queueTimeoutSeconds {
                return ["ok": false, "error": "queued \(Int(waited))s for a busy service (limit \(Int(queueTimeoutSeconds))s) — retry later"]
            }
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
        var req = request
        req["token"] = token
        waiting += 1
        inflight += 1
        lastUseAt = Date()
        publish()
        defer {
            waiting = max(0, waiting - 1)
            inflight = max(0, inflight - 1)
            lastUseAt = Date()
            // `MLX.Memory.peakMemory` is the one MLX call a request that never loaded
            // anything could otherwise reach; see `mlxTouched`.
            if mlxTouched { lastPeakMB = MLX.Memory.peakMemory / (1 << 20) }
            publish()
        }
        do {
            let out: [String: Any]
            switch cmd {
            case "generate": out = try await generate(req, tier: tier)
            case "edit": out = try await edit(req, tier: tier)
            default: out = try await vqa(req, tier: tier)
            }
            jobCounters.noteFinished(failed: false)
            return out
        } catch {
            // A cancelled job is neither a success nor a failure: it answers how
            // much work was abandoned, not how much broke. `is CancellationError`
            // is the check — NSError bridging of a cancellation carries no
            // stable domain/code to match on.
            if error is CancellationError {
                jobCounters.noteCancelled()
                return ["ok": false, "error": "cancelled", "cancelled": true, "token": token]
            }
            // Validation refusals (RequestError.bad, before any load) are not jobs:
            // they never touched the model, so counting them would conflate "callers
            // sending bad args" with "the service failing". Everything past
            // validation — a missing artifact, a load failure, a model error — is.
            let ns = error as NSError
            if !(ns.domain == "imagehive" && ns.code == 1) {
                jobCounters.noteFinished(failed: true)
                // A job that failed past validation may leave transient tensors
                // behind (half-run denoise, half-written output). Sweep them now
                // rather than carrying them into the next request's peak: the
                // weights stay resident, only the dregs go. Same gate as the
                // idle sweep — a failure that never touched MLX sweeps nothing.
                sweepCache()
            }
            // localizedDescription, not the NSError dump: this text is what the client
            // shows the user, and "Error Domain=... Code=1 UserInfo={...}" is not part
            // of the message.
            return ["ok": false, "error": ns.localizedDescription]
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
        let cfgOverride = try validatedGuidance(request, "cfg")
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
        p.cfgScale = cfgOverride ?? (distilled ? 1.0 : 4.0)
        p.seed = seed
        let (cond, uncond) = promptPair(tok, prompt, negative, cfg: p.cfgScale)
        let t0 = Date()
        jobProgress.begin("generate", total: p.numSteps, token: (request["token"] as? String) ?? "untracked")
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
        let cfgOverride = try validatedGuidance(request, "cfg")
        let imgCfgOverride = try validatedGuidance(request, "img_cfg")
        // Before ensureLoaded for the same reason as the sizes: a bad path is not worth
        // a 33 GiB load, and decoding needs no weights.
        let images = try loadReferences(request)
        let wanted = canonicalTier(tier)
        let resident = try await ensureLoaded(wanted)
        let m = resident.model
        let tok = resident.tokenizer
        var p = T2IParams()
        p.numSteps = stepsArg ?? 50
        p.cfgScale = cfgOverride ?? 4.0
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
        jobProgress.begin("edit", total: p.numSteps, token: (request["token"] as? String) ?? "untracked")
        defer { jobProgress.end() }
        let image = try m.it2iGenerate(
            condIds: condIds, imgCondIds: imgCondIds, uncondIds: nil, images: images,
            width: width, height: height, params: p,
            imgCfgScale: imgCfgOverride ?? 1.0,
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
            extra: ["img_cfg": imgCfgOverride ?? 1.0,
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

/// Writes every byte, or reports that this descriptor refused them — and never raises.
/// `FileHandle.write` raises an Objective-C exception when a write fails, which Swift
/// cannot catch, so one log line could take the whole shared service down. Measured
/// 2026-09-19: a daemon whose log reader went away died with SIGABRT on its next line
/// (`_objc_terminate` under `-[NSConcreteFileHandle writeData:]`); the same crash
/// reached the MCP front end twice that day. A full disk, an unlinked log file or a
/// closed descriptor must cost a line, not the process that holds the weights.
func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    var sent = 0
    return data.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return data.isEmpty }
        while sent < raw.count {
            let n = write(fd, base.advanced(by: sent), raw.count - sent)
            if n > 0 {
                sent += n
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
}

func log(_ message: String) {
    _ = writeAll(STDERR_FILENO, Data("imagehived: \(message)\n".utf8))
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
        log("set IMAGEHIVE_SOCKET to a shorter path, or move IMAGEHIVE_HOME somewhere shorter")
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
    // The backlog has to cover `maximumConnections` below, or a burst of parallel
    // clients is refused by the kernel before the accept loop can answer it: measured
    // 2026-09-19, 70 rapid connects died at 24 with a backlog of 16.
    guard bound == 0, listen(fd, 128) == 0 else {
        log("could not bind \(path): \(String(cString: strerror(errno)))")
        close(fd)
        return nil
    }
    // The socket file is the only gate in front of the service: whoever can
    // connect can ask for a generation, and the default umask leaves it
    // world-connectable on a multi-user Mac. 0600 keeps it to this user.
    // A failure refuses to serve rather than serving on an open socket.
    if chmod(path, 0o600) != 0 {
        log("could not restrict \(path) to owner-only: \(String(cString: strerror(errno)))")
        close(fd)
        unlink(path)
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
let terminationNotice = strdup("imagehived: terminated by signal — socket removed\n")!
let socketPathForSignal = strdup(socketPath)!
for signalNumber in [SIGTERM, SIGINT] {
    signal(signalNumber) { _ in
        _ = unlink(socketPathForSignal)
        _ = write(STDERR_FILENO, terminationNotice, strlen(terminationNotice))
        _exit(0)
    }
}
do {
    try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
} catch {
    log("could not create the socket directory: \(error)")
}
// createDirectory leaves an existing directory's permissions alone, so a home
// created under an older umask keeps whatever it had — the socket itself is the
// enforced boundary (see openListener), this only keeps new installs tight.

guard let listenFD = openListener(socketPath) else { exit(3) }
// Before the "listening" line, so the reason a setting did not take effect is in
// the log ahead of the evidence that the daemon came up anyway.
for warning in serviceConfig.warnings { log(warning) }
log("imagehived \(projectVersion) listening on \(socketPath) "
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
/// Whether a socket request names a model job (generate/edit/vqa). Only those
/// get a cancellation token and a tracked Task; status/options/unload/cancel
/// answer immediately and are never worth cancelling.
func isCancellable(_ request: [String: Any]) -> Bool {
    let cmd = (request["cmd"] as? String) ?? ""
    return cmd == "generate" || cmd == "edit" || cmd == "vqa"
}

/// Process-wide table of outstanding model jobs, keyed by token. It lives
/// outside any Connection because a `cancel` arrives on a different connection
/// from the job it stops — the caller learns the token from
/// `status.current.token`, which no single connection owns. Guarded by a serial
/// queue because entries are added/removed inside Tasks (async contexts, where
/// NSLock is unavailable under Swift 6 sendability rules).
final class JobRegistry: @unchecked Sendable {
    static let shared = JobRegistry()
    private let queue = DispatchQueue(label: "imagehive.registry")
    private var tasks: [String: Task<Void, Never>] = [:]

    /// Which connection started each job, so a disconnect cancels only its own
    /// jobs — other connections' generations keep running.
    private var owners: [String: ObjectIdentifier] = [:]

    /// Registers a task unless its owner has already gone away. The check and
    /// the insertion share this queue, and `Connection.disconnect` flips its
    /// flag before calling `cancelMine`, so a disconnect can only do one of two
    /// things: it is seen here (the task is refused and the caller cancels it),
    /// or it happens after registration (`cancelMine` finds the token). There is
    /// no interval where the token is invisible to both.
    @discardableResult
    func add(_ token: String, _ task: Task<Void, Never>, owner: Connection) -> Bool {
        var accepted = false
        queue.sync {
            guard !owner.isDisconnected else { return }
            tasks[token] = task
            owners[token] = ObjectIdentifier(owner)
            accepted = true
        }
        return accepted
    }
    func remove(_ token: String) {
        queue.sync {
            tasks.removeValue(forKey: token)
            owners.removeValue(forKey: token)
        }
    }
    func cancel(_ token: String) -> Bool {
        var task: Task<Void, Never>?
        queue.sync { task = tasks[token] }
        guard let task else { return false }
        task.cancel()
        return true
    }
    func cancelMine(_ owner: Connection) {
        let id = ObjectIdentifier(owner)
        var mine: [Task<Void, Never>] = []
        queue.sync {
            for (token, ownerId) in owners where ownerId == id {
                if let task = tasks[token] { mine.append(task) }
                tasks.removeValue(forKey: token)
                owners.removeValue(forKey: token)
            }
        }
        for task in mine { task.cancel() }
    }
}

final class Connection {
    private let fd: Int32
    private let writeQueue = DispatchQueue(label: "imagehive.write")
    private let core: Core
    /// One entry per model request still outstanding on this connection, keyed
    /// by its token. Cancelling a finished Task is a no-op, so entries are
    /// removed when the answer goes out — not when the Task ends — which also
    /// keeps a late `cancel` for a finished job answering "no such job".
    /// Serial queue guarding the process-wide task table below: registry
    /// access happens inside Tasks (async contexts), where `NSLock.lock()` is
    /// unavailable under Swift 6 sendability rules, so a queue owns the table.
    private let registry = JobRegistry.shared

    init(fd: Int32, core: Core) {
        self.fd = fd
        self.core = core
    }

    /// The connection thread sets this once, before cancelling its registered
    /// jobs. `JobRegistry.add` may read it from the registry queue, so it needs
    /// a lock. The flag is what closes the registration/disconnect race: either
    /// registration wins and `cancelMine` cancels the task, or this flag wins
    /// and registration refuses the task for the caller to cancel.
    private let stateLock = NSLock()
    private var disconnected = false

    var isDisconnected: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return disconnected
    }

    /// Mark the connection gone before touching the registry. Called exactly
    /// once, on the connection thread, when the read loop reaches EOF or an
    /// error.
    func disconnect() {
        stateLock.lock()
        let first = !disconnected
        disconnected = true
        stateLock.unlock()
        if first { registry.cancelMine(self) }
    }

    /// A waiter cancelled before it reaches the model still has to be counted
    /// and published immediately, even while the actor is busy with the job
    /// ahead of it. Kept outside the actor for that reason.
    private func noteQueuedCancellation(token: String) {
        registry.remove(token)
        jobCounters.noteCancelled()
        var snap = statusBoard.snapshot()
        let counts = jobCounters.snapshot()
        snap["jobs_total"] = counts.total
        snap["jobs_failed"] = counts.failed
        snap["jobs_cancelled"] = counts.cancelled
        statusBoard.publish(snap)
    }

    /// Interrupt the job named by `token`, if it is still outstanding on this
    /// connection. Synchronous: the Task is cancelled here, on the connection
    /// thread, without entering the actor queue behind the job it stops. The
    /// model loops check cancellation every denoise step (CAN cadence), so the
    /// job ends at the next step boundary; the queued Task then answers
    /// `{"ok":false,"error":"cancelled","cancelled":true}` to whoever is still
    /// listening — or to nobody, if the client already went away.
    func cancel(token: String) -> [String: Any] {
        guard registry.cancel(token) else {
            return ["ok": false, "error": "no such job '\(token)'"]
        }
        return ["ok": true, "cancelled": token]
    }

    /// The client went away: stop everything IT started. A batch client that is
    /// killed mid-run used to leave its generations burning GPU time to write
    /// PNGs nobody would read; now the jobs end at their next step boundary.
    /// Only this connection's tokens are cancelled — other connections' jobs
    /// keep running. (A connection that never sent a model job cancels nothing.)
    /// Quick (read-only) Tasks are tracked too, but they finish instantly, so
    /// cancelling them is a harmless no-op.

    /// One line, then close. Used to refuse a connection instead of dropping it: the
    /// protocol is one JSON object per line and a caller that gets nothing waits out its
    /// whole deadline, so a refusal has to say why.
    func refuse(_ reason: String) {
        var out = (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": reason] as [String: Any]))
            ?? Data(#"{"ok":false,"error":"too many clients"}"#.utf8)
        out.append(0x0A)
        _ = writeAll(fd, out)
        close(fd)
    }

    func start(onFinish: @escaping () -> Void) {
        // Borrowed into locals so the closures below need no implicit `self`.
        let fd = self.fd
        let writeQueue = self.writeQueue
        // `me` (below) carries the registry and the actor; the fd/queue locals
        // keep the hot path free of retain cycles that matter.
        let thread = Thread {
            // One JSON object per line, and the answer is written in the same shape.
            func send(_ data: Data) {
                writeQueue.sync {
                    var out = data
                    out.append(0x0A)
                    // `writeAll` retries EINTR and reports a peer that stopped reading;
                    // a reply that cannot be delivered is not an error worth tearing the
                    // connection down over, and a short write must still finish the line.
                    _ = writeAll(fd, out)
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
                // An interrupted read is not a client that went away: without this the
                // connection was dropped and the log blamed a request with no newline.
                if n < 0 && errno == EINTR { continue }
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
                    let parsed = ((try? JSONSerialization.jsonObject(with: line)) as? [String: Any]) ?? [:]
                    // `cancel` is answered here, on the connection thread: it must
                    // not enter the actor queue behind the very job it stops.
                    if (parsed["cmd"] as? String) == "cancel" {
                        guard let token = parsed["token"] as? String, !token.isEmpty else {
                            sendError("cancel needs a token — the token of a running job is in status.current.token")
                            continue
                        }
                        let response = self.cancel(token: token)
                        guard let data = try? JSONSerialization.data(withJSONObject: response) else { continue }
                        send(data)
                        continue
                    }
                    // Model jobs carry a token from here on: generated now (so a
                    // `cancel` arriving while the job queues already finds it),
                    // pinned into the request the actor sees (see handle).
                    var request = parsed
                    // A client-supplied token wins; a present-but-wrong-typed one
                    // is left alone for handle to refuse (strict keys, hard
                    // constraint 9) instead of being silently replaced here.
                    let token: String? = if !isCancellable(request) { nil }
                        else if let t = request["token"] as? String { t }
                        else if request["token"] == nil { UUID().uuidString }
                        else { nil }
                    if let token { request["token"] = token }
                    // Strong reference for the Task's lifetime: a job can outlive
                    // its connection (disconnect cancels it, but cancellation
                    // lands at the next step boundary), so the registry must
                    // stay valid until the Task removes itself.
                    let me = self
                    let task: Task<Void, Never> = Task {
                        // `status`, `options` and a busy `unload` are answered here, on
                        // the connection thread: during a generation the actor is held by
                        // the model call and would not reply until it finished (see
                        // StatusBoard). Everything that needs the model goes through it.
                        //
                        // Model jobs wait for their turn here, outside the actor, so a
                        // queue that never drains refuses instead of holding the caller
                        // past its deadline. The actor re-checks on entry (see handle):
                        // two waiters can both see an idle service and enter one after
                        // the other.
                        if let token {
                            request["queued_at"] = Date().timeIntervalSince1970
                            let queuedAt = Date()
                            // The wait can outlive the client: a caller that sent a
                            // job and hung up while queuing must not start burning
                            // GPU time after it left, so the loop polls for the
                            // disconnect (or cancel) alongside the timeout. Either
                            // way the waiter asked for work that never ran — count
                            // it as cancelled, not silent.
                            var queuedOutcome: String = "turn"
                            while statusBoard.snapshot()["inflight"] as? Int ?? 0 > 0 {
                                if Task.isCancelled {
                                    queuedOutcome = "cancelled"
                                    break
                                }
                                if Date().timeIntervalSince(queuedAt) > queueTimeoutSeconds {
                                    queuedOutcome = "timeout"
                                    break
                                }
                                try? await Task.sleep(nanoseconds: 200_000_000)
                            }
                            if queuedOutcome == "cancelled" {
                                me.noteQueuedCancellation(token: token)
                                return
                            }
                            if queuedOutcome == "timeout" {
                                me.registry.remove(token)
                                sendError("queued \(Int(Date().timeIntervalSince(queuedAt)))s for a busy service " +
                                    "(limit \(Int(queueTimeoutSeconds))s) — retry later")
                                return
                            }
                            // `Task.sleep` is cancelled by throwing, and the
                            // `try?` above turns that into an immediate loop
                            // turn. If the job ahead of us finished at the same
                            // moment, the `while` condition now sees zero and
                            // exits with `queuedOutcome == "turn"`. Do not
                            // mistake that for our turn: a cancelled waiter
                            // must never enter the model.
                            if Task.isCancelled {
                                me.noteQueuedCancellation(token: token)
                                return
                            }
                        }
                        if let quick = immediateAnswer(request) {
                            if let token {
                                me.registry.remove(token)
                            }
                            guard let data = try? JSONSerialization.data(withJSONObject: quick) else { return }
                            send(data)
                            return
                        }
                        let response = await me.core.handle(request)
                        if let token {
                            me.registry.remove(token)
                        }
                        guard let data = try? JSONSerialization.data(withJSONObject: response) else { return }
                        send(data)
                    }
                    if let token {
                        // Registration and disconnect are ordered through the
                        // registry: if the owner is already gone, `add` refuses
                        // the token and this cancellation is what stops the Task.
                        // That removes the old window where EOF cleanup could
                        // run before registration, find no token, and leave the
                        // task to start for a client that had already left.
                        if !me.registry.add(token, task, owner: me) {
                            task.cancel()
                        }
                    }
                }
            }
            self.disconnect()
            close(fd)
            onFinish()
        }
        thread.stackSize = 1 << 20
        thread.start()
    }
}

/// How many clients may hold a connection at once. Each one costs a thread parked in
/// `read`, and nothing else in this process is bounded: a client that leaks connections
/// (a loop, a crash that never closes, a tool that opens a socket per request) could
/// otherwise grow the daemon without limit. 64 is far above any real setup — a front end
/// holds exactly one connection for the life of a session, and generations are
/// serialized inside the actor anyway.
let maximumConnections = 64

final class ConnectionCount {
    private let lock = NSLock()
    private var live = 0

    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard live < maximumConnections else { return false }
        live += 1
        return true
    }

    func release() {
        lock.lock(); live -= 1; lock.unlock()
    }
}

let connectionCount = ConnectionCount()

let acceptThread = Thread {
    while true {
        let client = accept(listenFD, nil, nil)
        if client < 0 {
            if errno == EINTR { continue }
            Thread.sleep(forTimeInterval: 0.2)
            continue
        }
        let connection = Connection(fd: client, core: core)
        guard connectionCount.take() else {
            connection.refuse("too many clients: \(maximumConnections) connections are already open. "
                + "The service serializes generations, so one connection per client is enough.")
            continue
        }
        connection.start { connectionCount.release() }
    }
}
acceptThread.stackSize = 1 << 20
acceptThread.start()
RunLoop.main.run()
