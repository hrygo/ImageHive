// sensenova-served - resident SenseNova-U1.5 image service.
//
// Local addition (not upstream). One process owns the weights; clients talk to
// it over a unix-domain socket using newline-delimited JSON, the same framing
// MCP uses for stdio (MCP spec 2026-07-28, "Custom Transports").
//
// Responsibilities:
//   single instance  - socket bind is the mutex; a second process exits
//   single resident  - one tier loaded at a time, generations serialized
//   idle unload      - TTL after last use, with a minimum warm time
//   observable       - loads_total / resident_tier / inflight / queue_depth
//
// Environment: SENSENOVA_HOME, SENSENOVA_TTL_SECONDS (600),
// SENSENOVA_MIN_WARM_SECONDS (60), SENSENOVA_SOCKET.

import CoreGraphics
import Foundation
import ImageIO
import MLX
import SenseNovaU1
import UniformTypeIdentifiers

let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SENSENOVA_HOME"]
    ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Models/SenseNova-U1.5").path)
let ttlSeconds = Double(ProcessInfo.processInfo.environment["SENSENOVA_TTL_SECONDS"] ?? "600") ?? 600
let minWarmSeconds = Double(ProcessInfo.processInfo.environment["SENSENOVA_MIN_WARM_SECONDS"] ?? "60") ?? 60
let socketPath = ProcessInfo.processInfo.environment["SENSENOVA_SOCKET"]
    ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/SenseNovaU1/served.sock").path
let outDir = home.appendingPathComponent("out")

func artifactDir(_ tier: String) -> URL {
    switch tier {
    case "fast", "8step", "fast8":
        return home.appendingPathComponent("artifacts/SenseNova-U1.5-8B-MoT-bf16-8step")
    default:
        return home.appendingPathComponent("artifacts/SenseNova-U1.5-8B-MoT-bf16")
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

    func status() -> [String: Any] {
        var out: [String: Any] = [
            "resident_tier": residentTier ?? "cold",
            "loads_total": loadsTotal,
            "inflight": inflight,
            "queue_depth": waiting,
            "ttl_seconds": ttlSeconds,
            "min_warm_seconds": minWarmSeconds,
            "last_peak_mb": lastPeakMB,
        ]
        if let d = lastUseAt { out["last_request_at"] = ISO8601DateFormatter().string(from: d) }
        if let d = loadedAt { out["loaded_at"] = ISO8601DateFormatter().string(from: d) }
        return out
    }

    private func release() {
        model = nil
        tokenizer = nil
        residentTier = nil
        loadedAt = nil
        MLX.Memory.clearCache()
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

    private func ensureLoaded(_ tier: String) async throws -> Resident {
        if let m = model, let t = tokenizer, residentTier == tier {
            return Resident(model: m, tokenizer: t)
        }
        if let pending = pendingLoad {
            if pending.tier == tier { return try await pending.task.value }
            throw NSError(domain: "sensenova", code: 4, userInfo: [NSLocalizedDescriptionKey:
                "busy loading tier '\(pending.tier)'; retry once it settles"])
        }
        if model != nil { release() }
        let dir = artifactDir(tier)
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path) else {
            throw NSError(domain: "sensenova", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "artifact missing: \(dir.path)"])
        }
        let t0 = Date()
        let task = Task.detached(priority: .userInitiated) { () throws -> Resident in
            let m = try WeightLoading.loadArtifact(from: dir)
            let t = try await SenseNovaTokenizer.load(from: dir)
            return Resident(model: m, tokenizer: t)
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
        log("loaded \(tier) in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s (loads_total=\(loadsTotal))")
        return resident
    }

    func handle(_ request: [String: Any]) async -> [String: Any] {
        let cmd = (request["cmd"] as? String) ?? ""
        if cmd == "status" { return ["ok": true, "status": status()] }
        if cmd == "unload" {
            guard inflight == 0 else { return ["ok": false, "error": "busy"] }
            return unload()
        }
        guard cmd == "generate" || cmd == "edit" || cmd == "vqa" else {
            return ["ok": false, "error": "unknown cmd '\(cmd)'"]
        }

        let distilledFloor = request["steps"] as? Int ?? 50
        let tier = (request["tier"] as? String)
            ?? (cmd == "generate" && distilledFloor <= 12 ? "fast" : "quality")
        waiting += 1
        inflight += 1
        lastUseAt = Date()
        defer {
            waiting = max(0, waiting - 1)
            inflight = max(0, inflight - 1)
            lastUseAt = Date()
            lastPeakMB = MLX.Memory.peakMemory / (1 << 20)
        }
        do {
            switch cmd {
            case "generate": return try await generate(request, tier: tier)
            case "edit": return try await edit(request, tier: tier)
            default: return try await vqa(request, tier: tier)
            }
        } catch {
            return ["ok": false, "error": String(describing: error)]
        }
    }

    private func promptPair(_ tok: SenseNovaTokenizer, _ prompt: String, cfg: Float) -> ([Int32], [Int32]?) {
        let pair = tok.t2iIDs(prompt: prompt)
        return (pair.cond, cfg > 1 ? pair.uncond : nil)
    }

    private func generate(_ request: [String: Any], tier: String) async throws -> [String: Any] {
        let resident = try await ensureLoaded(tier)
        let m = resident.model
        let tok = resident.tokenizer
        let distilled = tier == "fast"
        let prompt = request["prompt"] as? String ?? ""
        var p = T2IParams()
        p.numSteps = request["steps"] as? Int ?? (distilled ? 8 : 50)
        p.cfgScale = Float(request["cfg"] as? Double ?? (distilled ? 1.0 : 4.0))
        p.seed = UInt64(request["seed"] as? Int ?? Int.random(in: 1...2_000_000))
        let width = request["width"] as? Int ?? 1024
        let height = request["height"] as? Int ?? 1024
        let (cond, uncond) = promptPair(tok, prompt, cfg: p.cfgScale)
        let t0 = Date()
        let image = try m.t2iGenerate(
            condIds: cond, uncondIds: uncond, width: width, height: height, params: p)
        eval(image)
        let seconds = Date().timeIntervalSince(t0)
        let url = try writeOutput(image, tag: distilled ? "fast\(p.numSteps)" : "t2i", seed: p.seed)
        return [
            "ok": true, "path": url.path, "tier": tier, "seed": Int(p.seed),
            "steps": p.numSteps, "cfg": Double(p.cfgScale), "width": width, "height": height,
            "seconds": (seconds * 100).rounded() / 100, "peak_mb": MLX.Memory.peakMemory / (1 << 20),
        ]
    }

    private func loadReferences(_ request: [String: Any]) throws -> [EditImage] {
        let paths = request["images"] as? [String] ?? []
        guard !paths.isEmpty else {
            throw NSError(domain: "sensenova", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "images[] is required"])
        }
        return try paths.map { try SenseNovaImageIO.loadEditImage(url: URL(fileURLWithPath: $0)) }
    }

    private func edit(_ request: [String: Any], tier: String) async throws -> [String: Any] {
        let resident = try await ensureLoaded(tier)
        let m = resident.model
        let tok = resident.tokenizer
        let prompt = request["prompt"] as? String ?? ""
        let images = try loadReferences(request)
        var p = T2IParams()
        p.numSteps = request["steps"] as? Int ?? 50
        p.cfgScale = Float(request["cfg"] as? Double ?? 4.0)
        p.seed = UInt64(request["seed"] as? Int ?? Int.random(in: 1...2_000_000))
        let counts = images.map(\.tokenCount)
        var width = request["width"] as? Int ?? 0
        var height = request["height"] as? Int ?? 0
        if width == 0 || height == 0 {
            let target = request["target_pixels"] as? Int ?? (2048 * 2048)
            let (h, w) = SenseNovaImageIO.smartResize(
                height: images[0].gridH * 16, width: images[0].gridW * 16, factor: 32,
                minPixels: target, maxPixels: target)
            width = w
            height = h
        }
        let condIds = try tok.encode(Conversation.editCondPrompt(prompt, imageTokenCounts: counts))
        let imgCondIds = try tok.encode(Conversation.editImgCondPrompt(imageTokenCounts: counts))
        let t0 = Date()
        let image = try m.it2iGenerate(
            condIds: condIds, imgCondIds: imgCondIds, uncondIds: nil, images: images,
            width: width, height: height, params: p,
            imgCfgScale: Float(request["img_cfg"] as? Double ?? 1.0))
        eval(image)
        let seconds = Date().timeIntervalSince(t0)
        let url = try writeOutput(image, tag: "edit", seed: p.seed)
        return [
            "ok": true, "path": url.path, "tier": tier, "seed": Int(p.seed),
            "steps": p.numSteps, "cfg": Double(p.cfgScale), "width": width, "height": height,
            "seconds": (seconds * 100).rounded() / 100, "peak_mb": MLX.Memory.peakMemory / (1 << 20),
        ]
    }

    private func vqa(_ request: [String: Any], tier: String) async throws -> [String: Any] {
        let resident = try await ensureLoaded(tier)
        let m = resident.model
        let tok = resident.tokenizer
        let question = request["prompt"] as? String ?? ""
        let paths = request["images"] as? [String] ?? []
        let images: [EditImage] = paths.compactMap {
            try? SenseNovaImageIO.loadEditImage(url: URL(fileURLWithPath: $0))
        }
        var message = question
        if !images.isEmpty {
            message = try Conversation.expandImagePlaceholders(
                prompt: String(repeating: "<image>\n", count: images.count) + question,
                imageTokenCounts: images.map(\.tokenCount))
        }
        let ids = tok.encode(Conversation.vqaPrompt(
            userMessage: message, think: request["think"] as? Bool ?? false))
        var sampling = SamplingParams()
        sampling.maxNewTokens = request["max_tokens"] as? Int ?? 512
        let t0 = Date()
        let answer = try m.chat(ids: ids, images: images, params: sampling)
        let seconds = Date().timeIntervalSince(t0)
        let (text, reasoning) = Conversation.splitReasoning(tok.decode(answer))
        var out: [String: Any] = [
            "ok": true, "text": text, "tier": tier,
            "seconds": (seconds * 100).rounded() / 100, "peak_mb": MLX.Memory.peakMemory / (1 << 20),
        ]
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
    guard fd >= 0 else { return nil }
    let bound = withSockaddr(path) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    guard bound == 0, listen(fd, 16) == 0 else {
        close(fd)
        return nil
    }
    return fd
}

let core = Core()
signal(SIGPIPE, SIG_IGN)
try? FileManager.default.createDirectory(
    at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
    withIntermediateDirectories: true)

guard let listenFD = openListener(socketPath) else { exit(3) }
log("listening on \(socketPath) (ttl \(Int(ttlSeconds))s, min warm \(Int(minWarmSeconds))s)")

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
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = read(fd, &chunk, chunk.count)
                if n <= 0 { break }
                buffer.append(contentsOf: chunk[0..<n])
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: buffer.startIndex..<newline)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard !line.isEmpty else { continue }
                    Task {
                        let payload = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
                        let response = await core.handle(payload ?? [:])
                        guard let data = try? JSONSerialization.data(withJSONObject: response) else { return }
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
