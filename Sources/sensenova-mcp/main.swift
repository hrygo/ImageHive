// sensenova-mcp - stdio MCP front end for the resident SenseNova-U1.5 service.
//
// Local addition (not upstream). This process is deliberately stateless and
// never touches the weights: it speaks MCP on stdio and forwards every call
// over the unix-domain socket owned by `sensenova-served`, which is what
// actually holds the single resident copy of the model. Launching a second MCP
// client therefore costs one small process, not another 34 GB of weights.
//
// Protocol: serves both the legacy `initialize` handshake (2025-11-25) and the
// 2026-07-28 revision's stateless `server/discover`, and only emits the newer
// envelope fields (resultType / ttlMs / cacheScope) once a client has shown it
// speaks that revision.
//
// Environment: SENSENOVA_HOME, SENSENOVA_SOCKET, SENSENOVA_SERVED_BIN.

import Foundation

/// The project version — `cli/lib/common.sh`'s `SV_VERSION`, written into
/// `service.conf` by install.sh. Reported here and in `serverInfo` so a client log
/// says which build answered; it used to print `0.1.0`, a number that matched no
/// release. Same rule as the daemon; `unknown` when nothing says otherwise.
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

let earlyHome = ProcessInfo.processInfo.environment["HOME"]
    ?? FileManager.default.homeDirectoryForCurrentUser.path
let serviceVersion = ProcessInfo.processInfo.environment["SENSENOVA_VERSION"]
    ?? confValue("SENSENOVA_VERSION", in: ProcessInfo.processInfo.environment["SENSENOVA_CONF"]
        ?? "\(ProcessInfo.processInfo.environment["SENSENOVA_HOME"] ?? "\(earlyHome)/Library/Application Support/SenseNovaU1")/service.conf")
    ?? "unknown"
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--version") || arguments.contains("-v") {
    print("sensenova-mcp \(serviceVersion)")
    exit(0)
}
if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    sensenova-mcp \(serviceVersion) — stdio MCP front end for the local SenseNova-U1.5 image service

    Speaks MCP on stdin/stdout and forwards to the resident sensenova-served daemon,
    starting it on demand. No arguments are needed; MCP clients launch it directly.

    Environment: SENSENOVA_HOME, SENSENOVA_SOCKET, SENSENOVA_SERVED_BIN,
    SENSENOVA_MODELS, SENSENOVA_OUT.
    """)
    exit(0)
}

// MARK: - configuration

let environment = ProcessInfo.processInfo.environment
// $HOME first, then the passwd entry — same rule as the daemon and the CLI.
let userHome = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
let homePath = environment["SENSENOVA_HOME"]
    ?? "\(userHome)/Library/Application Support/SenseNovaU1"
let socketPath = environment["SENSENOVA_SOCKET"] ?? "\(homePath)/served.sock"
/// Where the daemon lives. `SENSENOVA_SERVED_BIN` is what the installer writes into
/// every client entry, so it wins. Next to this front end is the next best answer
/// and the one that cannot be wrong — the two binaries are installed into the same
/// directory — whereas the prefix-based default is wrong for every install that used
/// `--prefix`: a front end launched without the environment (a plain `sensenova-u1
/// status`) then looked under `~/.local/share` and reported "sensenova-served not
/// found" on an install that was perfectly fine.
let servedBinaryPath: String = {
    if let explicit = environment["SENSENOVA_SERVED_BIN"], !explicit.isEmpty { return explicit }
    if let here = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() {
        let beside = here.appendingPathComponent("sensenova-served").path
        if FileManager.default.isExecutableFile(atPath: beside) { return beside }
    }
    return "\(environment["SENSENOVA_PREFIX"] ?? "\(userHome)/.local")/share/sensenova-u1/bin/sensenova-served"
}()

let latestRevision = "2026-07-28"
let legacyRevision = "2025-11-25"
let supportedRevisions = [latestRevision, legacyRevision]
let serverName = "sensenova-u1"
let serverTitle = "SenseNova-U1.5 local image service"
let serverVersion = "1.0.0"
let listTTLms = 60_000

/// True once the client has proven it speaks the 2026-07-28 revision (via
/// `server/discover` or by naming that version in `initialize`). Older clients
/// get the legacy envelope only, so nothing unexpected lands in their parsers.
var modernEnvelope = false

func log(_ message: String) {
    FileHandle.standardError.write("sensenova-mcp: \(message)\n".data(using: .utf8)!)
}

let serverInstructions = """
Local SenseNova-U1.5 (8B Mixture-of-Transformers, bf16, no quantisation) image \
service running on this Mac. Every client shares one resident copy of the \
weights: the first call after an idle period pays a one-time load (about 6 \
seconds) and later calls reuse it, so do not try to "warm up" the model \
yourself and do not unload it between requests.

Tools: generate_image (text to image), edit_image (instruction editing with \
reference images), describe_image (visual question answering), model_status, \
unload_model.

Tier choice: tier=fast is the 8-step distilled LoRA (about 6 s for 1024x1024) \
and is right for drafts, iteration and thumbnails; tier=quality is the 50-step \
bf16 reference path (about 50 s for 1024x1024) and is right for final art and \
anything with text in it. Both tiers need the same memory while resident, so \
pick on quality grounds, not on memory grounds. A tier is a preference: a \
machine may have installed only one of the two artifacts (that is a normal \
setup), in which case a request for the missing tier is served by the installed \
one using that artifact's own recipe, and the reply names the tier that \
actually ran. model_status reports available_tiers, so you can ask which ones \
this machine has before choosing.

Generations are serialized inside the daemon; a second request waits its turn. \
Tools return the absolute path of the PNG they wrote - read that file when you \
need to look at the image. Reference images for edit_image and describe_image \
must be absolute local paths. TTL unload is automatic (default 600 s idle); \
call unload_model only when you actively want the 34 GB back.
"""

// MARK: - daemon client

struct DaemonError: Error, CustomStringConvertible {
    let description: String
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

func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    var sent = 0
    return data.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return false }
        while sent < raw.count {
            let n = write(fd, base.advanced(by: sent), raw.count - sent)
            if n <= 0 { return false }
            sent += n
        }
        return true
    }
}

/// Talks newline-delimited JSON to `sensenova-served`, spawning it on demand.
final class DaemonClient {
    private var fd: Int32 = -1
    private var pending = Data()
    private var child: Process?
    private var childLog: FileHandle?
    private let lock = NSLock()
    private var spawned = false
    /// Why the last spawn attempt could not even start the process. Kept so a broken
    /// install fails immediately: without it every request polled for the full 30 s
    /// handshake deadline before saying anything, which reads as a hung service.
    private var spawnError: String?
    /// Written into the "could not reach" message — the daemon explains itself there
    /// (a socket path that is too long, a port clash, a missing artifact).
    private var daemonLogPath: String?

    private func connectOnce() -> Bool {
        let raw = socket(AF_UNIX, SOCK_STREAM, 0)
        guard raw >= 0 else { return false }
        let result = withSockaddr(socketPath) { connect(raw, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        guard result == 0 else {
            close(raw)
            return false
        }
        fd = raw
        return true
    }

    private func spawnServed() {
        guard !spawned else { return }
        spawned = true
        guard FileManager.default.fileExists(atPath: servedBinaryPath) else {
            spawnError = "the local image service is not installed: no sensenova-served at "
                + "\(servedBinaryPath) — run install.sh"
            log(spawnError!)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: servedBinaryPath)
        var env = ProcessInfo.processInfo.environment
        env["SENSENOVA_HOME"] = homePath
        env["SENSENOVA_SOCKET"] = socketPath
        process.environment = env
        // The daemon outlives this front end, so its log lines go to a file
        // rather than to a stderr pipe that will be closed when we exit.
        // $HOME first, like every other path here: a sandboxed or overridden HOME
        // must not write its daemon log into the real user's log directory.
        let logDirectory = URL(fileURLWithPath: userHome)
            .appendingPathComponent("Library/Logs/SenseNovaU1")
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let logPath = logDirectory.appendingPathComponent("served.log").path
        daemonLogPath = logPath
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        let handle = FileHandle(forWritingAtPath: logPath)
        _ = try? handle?.seekToEnd()
        process.standardOutput = handle ?? FileHandle.standardError
        process.standardError = handle ?? FileHandle.standardError
        childLog = handle
        do {
            try process.run()
            child = process
            log("started sensenova-served (pid \(process.processIdentifier))")
        } catch {
            spawnError = "could not start sensenova-served: \(error)"
            log(spawnError!)
        }
    }

    /// Connect, starting the daemon if needed. The daemon binds the socket only
    /// after it is ready to accept, so a bounded poll is the whole handshake.
    private func connectToDaemon() throws {
        // sun_path holds 103 bytes plus the NUL; a longer path must be refused
        // here rather than truncated, or the front end would connect somewhere
        // else entirely and report "daemon unreachable" forever.
        guard socketPath.utf8.count < 104 else {
            throw DaemonError(description: """
                socket path is too long: \(socketPath.utf8.count) bytes, macOS allows 103.
                Point SENSENOVA_SOCKET (or SENSENOVA_HOME) at something shorter.
                """)
        }
        if connectOnce() { return }
        spawnServed()
        // Nothing to wait for: the process never came up, so the 30 s poll below
        // would only delay the same answer.
        if let spawnError { throw DaemonError(description: spawnError) }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            if connectOnce() { return }
        }
        throw DaemonError(description: """
            sensenova-served did not answer on \(socketPath) within 30s (binary \
            \(servedBinaryPath)). Its log explains why: \(daemonLogPath ?? "(no log path)")
            """)
    }

    private func readMessage() -> Data? {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let index = pending.firstIndex(of: 0x0A) {
                let line = pending.subdata(in: pending.startIndex..<index)
                pending.removeSubrange(pending.startIndex...index)
                if line.isEmpty { continue }
                return line
            }
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            pending.append(contentsOf: chunk[0..<n])
        }
    }

    private func roundTrip(_ payload: [String: Any]) throws -> [String: Any] {
        var request = try JSONSerialization.data(withJSONObject: payload)
        request.append(0x0A)
        guard writeAll(fd, request) else {
            throw DaemonError(description: "write to sensenova-served failed")
        }
        guard let line = readMessage() else {
            throw DaemonError(description: """
                the local image service stopped while this request was running — it was \
                restarted, stopped or crashed. An image is written before the reply is sent, \
                so this request may have left a file behind even though it failed; check the \
                output directory. Run `sensenova-u1 status` to see where the service is.
                """)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            throw DaemonError(description: "unreadable response from sensenova-served")
        }
        return object
    }

    private func dropConnection() {
        if fd >= 0 { close(fd) }
        fd = -1
        pending.removeAll()
    }

    /// Serialized on purpose: one MCP front end is one caller, and the daemon
    /// serializes generations anyway.
    ///
    /// Retrying after a dropped connection is only safe for requests that change
    /// nothing: a render writes its PNG *before* the reply goes out, so a retry after
    /// a daemon that died in between would write a second file under a second name and
    /// the caller — an agent comparing runs, typically — would never learn that its
    /// sample set now has an extra image in it. Read-only requests are retried; a
    /// dropped render is reported instead.
    private func isRetryable(_ payload: [String: Any]) -> Bool {
        let cmd = (payload["cmd"] as? String) ?? ""
        return cmd == "vqa" || ["status", "options", "unload"].contains(cmd)
    }

    func call(_ payload: [String: Any]) throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        var lastError: Error = DaemonError(description: "unreachable")
        var attempts = isRetryable(payload) ? 2 : 1
        while attempts > 0 {
            attempts -= 1
            do {
                if fd < 0 { try connectToDaemon() }
                return try roundTrip(payload)
            } catch {
                lastError = error
                // Only a connection that was *lost* is worth retrying. A daemon that
                // never answered has already been waited for — the handshake poll — and
                // retrying it just doubles the wait before the same message (measured:
                // a socket path the daemon cannot bind kept `--status` waiting 60 s).
                let wasConnected = fd >= 0
                dropConnection()
                if !wasConnected { break }
            }
        }
        throw lastError
    }
}

let daemon = DaemonClient()

// MARK: - management switches (never used by MCP clients, handy for humans)

func runManagementSwitch(_ flag: String) {
    switch flag {
    case "--status":
        // The real reason, not just "unreachable": it now names the log file and the
        // binary path, which is what turns this into something a user can act on.
        let response: [String: Any]
        do {
            response = try daemon.call(["cmd": "status"])
        } catch {
            print("daemon unreachable — \(error)")
            exit(1)
        }
        guard let status = response["status"] as? [String: Any] else {
            print("daemon answered without a status block")
            exit(1)
        }
        let resident = (status["resident_tier"] as? String) ?? "cold"
        let installed = (status["available_tiers"] as? [String])?.joined(separator: ",") ?? "?"
        let loads = status["loads_total"] as? Int ?? 0
        let inflight = status["inflight"] as? Int ?? 0
        let queued = status["queue_depth"] as? Int ?? 0
        let ttl = status["ttl_seconds"] as? Double ?? 0
        let peak = status["last_peak_mb"] as? Int ?? 0
        print("resident_tier=\(resident)")
        print("available_tiers=\(installed)")
        print("loads_total=\(loads)")
        print("inflight=\(inflight)")
        print("queue_depth=\(queued)")
        print("ttl_seconds=\(Int(ttl))")
        print("last_peak_mb=\(peak)")
        // Which build is answering, and which process. A daemon started by an older
        // install (or by hand) keeps the socket, so after an upgrade the answers can
        // still come from the previous binary; this is what makes that visible.
        print("pid=\(status["pid"] as? Int ?? 0)")
        print("project_version=\((status["project_version"] as? String) ?? "unknown")")
        print("protocol=\(status["protocol"] as? Int ?? 0)")
        if let when = status["last_request_at"] as? String { print("last_request_at=\(when)") }
        // Live progress, so `sensenova-u1 status` is useful while it runs rather than
        // just saying inflight=1.
        if let current = status["current"] as? [String: Any] {
            print("current=\(current["tool"] as? String ?? "job") "
                + "step \(intValue(current["step"]) ?? 0)/\(intValue(current["total"]) ?? 0) "
                + "\(intValue(current["percent"]) ?? 0)% "
                + "elapsed \(doubleValue(current["elapsed_seconds"]) ?? 0)s")
        }
        // Settings the daemon could not read out of config.json. They are only ever
        // absent when the file is fine, so printing them when present keeps the usual
        // output unchanged while making a silent fallback to the defaults visible.
        for warning in (status["config_warnings"] as? [String]) ?? [] {
            print("config_warning=\(warning)")
        }
    case "--unload":
        let response: [String: Any]
        do {
            response = try daemon.call(["cmd": "unload"])
        } catch {
            print("could not unload — \(error)")
            exit(1)
        }
        guard (response["ok"] as? Bool) == true else {
            print("could not unload: \((response["error"] as? String) ?? "the daemon refused without saying why")")
            exit(1)
        }
        print("released \((response["unloaded"] as? String) ?? "none"); resident_tier=cold")
    default:
        break
    }
    exit(0)
}

for flag in arguments where flag == "--status" || flag == "--unload" {
    runManagementSwitch(flag)
}

// MARK: - MCP tool catalogue

func json(_ text: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
}

let toolCatalogue: [[String: Any]] = [
    json(#"""
    {
      "name": "generate_image",
      "title": "Generate an image",
      "description": "Draw a new image from a text prompt with the local SenseNova-U1.5 8B model. Returns the absolute path of the PNG it wrote, plus timing. Use tier=fast for drafts and iteration (8-step distilled LoRA, about 6 s at 1024x1024) and tier=quality for final art or anything containing text (50 steps, about 50 s). Both tiers need the same memory while resident; on a machine that installed only one of the two artifacts, the request is served by the installed one at that artifact's own settings and the reply says so. Prompts in Chinese and English both work; for posters or logos put the literal text you want rendered in quotes inside the prompt.",
      "inputSchema": {
        "type": "object",
        "properties": {
          "prompt": {
            "type": "string",
            "description": "What to draw. Be specific about subject, style, lighting and composition; quote literal text that must appear in the image."
          },
          "tier": {
            "type": "string",
            "enum": ["fast", "quality"],
            "default": "quality",
            "description": "fast = 8-step distilled LoRA (default 8 steps, cfg 1.0); quality = bf16 reference path (default 50 steps, cfg 4.0). A preference, not a requirement: if that artifact is not installed on this machine the other one serves the request at its own defaults, and the reply's tier field names what actually ran."
          },
          "width": {"type": "integer", "minimum": 256, "default": 1024, "description": "Pixels, multiple of 32."},
          "height": {"type": "integer", "minimum": 256, "default": 1024, "description": "Pixels, multiple of 32."},
          "steps": {"type": "integer", "minimum": 1, "maximum": 100, "description": "Diffusion steps; omit for the tier default."},
          "cfg": {"type": "number", "description": "Classifier-free guidance scale; omit for the tier default."},
          "seed": {"type": "integer", "description": "Fixes generation for reproducibility; omit for random."},
          "negative": {
            "type": "string",
            "description": "What the image should avoid, for example: blurry, watermark, extra fingers. This is the unconditional branch of guidance, so it only bites when guidance is on (the quality recipe, cfg > 1); with cfg 1.0 it is ignored. The reply and the sidecar record it either way."
          },
          "inline_thumbnail": {
            "type": "boolean",
            "default": false,
            "description": "Also return the PNG inline as an image block (costs context; the file path is always returned)."
          }
        },
        "required": ["prompt"],
        "additionalProperties": false
      },
      "annotations": {"title": "Generate an image", "readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false}
    }
    """#),
    json(#"""
    {
      "name": "edit_image",
      "title": "Edit an image",
      "description": "Edit or restyle existing local images with a natural-language instruction, using the same SenseNova-U1.5 model in image-edit mode. Pass absolute paths of the reference images; the result is written to a new PNG whose path is returned. One instruction per call: describe the change and, when it matters, what must stay untouched (identity, layout, remaining text). A negative prompt is not supported here — the edit surface has no unconditional branch, so a non-empty negative is rejected rather than silently ignored; put the constraint in the instruction instead.",
      "inputSchema": {
        "type": "object",
        "properties": {
          "prompt": {
            "type": "string",
            "description": "The edit instruction, for example: change the sky to a stormy dusk, keep the buildings and the sign exactly as they are."
          },
          "images": {
            "type": "array",
            "items": {"type": "string"},
            "minItems": 1,
            "description": "Absolute paths of the reference image files on this Mac."
          },
          "tier": {
            "type": "string",
            "enum": ["fast", "quality"],
            "default": "quality",
            "description": "fast = 8-step distilled LoRA; quality = 50-step bf16 reference path. A preference, not a requirement: if that artifact is not installed, the other one serves the request and the reply says which tier ran."
          },
          "width": {"type": "integer", "description": "Output width in pixels; omit to derive it from target_pixels and the reference aspect ratio."},
          "height": {"type": "integer", "description": "Output height in pixels; omit to derive it from target_pixels and the reference aspect ratio."},
          "target_pixels": {"type": "integer", "default": 4194304, "description": "Area budget used when width/height are omitted; default 2048x2048 equivalent."},
          "steps": {"type": "integer", "minimum": 1, "maximum": 100},
          "cfg": {"type": "number"},
          "img_cfg": {"type": "number", "default": 1.0, "description": "Image-guidance scale; raise it to follow the reference more literally."},
          "seed": {"type": "integer"},
          "inline_thumbnail": {"type": "boolean", "default": false}
        },
        "required": ["prompt", "images"],
        "additionalProperties": false
      },
      "annotations": {"title": "Edit an image", "readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false}
    }
    """#),
    json(#"""
    {
      "name": "describe_image",
      "title": "Describe or read an image",
      "description": "Answer a question about one or more local images (visual question answering, reusing the same resident weights - no second model is loaded). Good for reading text out of a rendering, checking whether a generated image matches the brief, or comparing two candidates. Returns text only; nothing is written to disk.",
      "inputSchema": {
        "type": "object",
        "properties": {
          "prompt": {
            "type": "string",
            "default": "Describe this image in detail.",
            "description": "The question or instruction about the image(s)."
          },
          "images": {
            "type": "array",
            "items": {"type": "string"},
            "minItems": 1,
            "description": "Absolute paths of the image files to look at."
          },
          "think": {"type": "boolean", "default": false, "description": "Let the model reason before answering; slower but better on counting and reading text."},
          "max_tokens": {"type": "integer", "default": 512, "minimum": 16}
        },
        "required": ["images"],
        "additionalProperties": false
      },
      "annotations": {"title": "Describe or read an image", "readOnlyHint": true, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false}
    }
    """#),
    json(#"""
    {
      "name": "model_options",
      "title": "What the image model accepts",
      "description": "Report what this service accepts before anything is asked of it: the sizes it can render (multiples of 32, with recommended 1:1, 3:2 and 16:9 values), the steps and cfg ranges with their per-tier defaults, that the seed is reproducible, that a negative prompt applies to generate_image but not to edit_image, where the sidecar metadata lands, which tiers are installed here, and that a dispatched request cannot be cancelled. Read-only, and it answers immediately even while another generation is running.",
      "inputSchema": {"type": "object", "properties": {}, "additionalProperties": false},
      "annotations": {"title": "What the image model accepts", "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false}
    }
    """#),
    json(#"""
    {
      "name": "model_status",
      "title": "Image model status",
      "description": "Report the state of the shared local image service: which weights are resident, how many times they have been loaded since boot, how many generations are queued or in flight, the idle-unload TTL, and the peak memory of the last job. Use it to decide whether a call will pay a model load, or to confirm that no duplicate copy is resident.",
      "inputSchema": {"type": "object", "properties": {}, "additionalProperties": false},
      "annotations": {"title": "Image model status", "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false}
    }
    """#),
    json(#"""
    {
      "name": "unload_model",
      "title": "Release the image model",
      "description": "Release the resident image weights immediately and give back about 34 GB of unified memory, instead of waiting for the idle TTL. The next generate/edit/describe call reloads them (about 6 s). Refused while a generation is running. Shared state: unloading affects every client of this service, so do it only when you are finished for a while.",
      "inputSchema": {"type": "object", "properties": {}, "additionalProperties": false},
      "annotations": {"title": "Release the image model", "readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false}
    }
    """#),
]

// MARK: - argument helpers

func intValue(_ any: Any?) -> Int? {
    if let n = any as? Int { return n }
    if let d = any as? Double { return Int(d) }
    if let n = any as? NSNumber { return n.intValue }
    if let s = any as? String { return Int(s) }
    return nil
}

func doubleValue(_ any: Any?) -> Double? {
    if let d = any as? Double { return d }
    if let n = any as? Int { return Double(n) }
    if let n = any as? NSNumber { return n.doubleValue }
    if let s = any as? String { return Double(s) }
    return nil
}

func boolValue(_ any: Any?) -> Bool? {
    if let b = any as? Bool { return b }
    if let n = any as? NSNumber { return n.boolValue }
    if let s = any as? String { return ["true", "1", "yes"].contains(s.lowercased()) }
    return nil
}

func stringList(_ any: Any?) -> [String]? {
    if let list = any as? [String] { return list }
    if let list = any as? [Any] { return list.compactMap { $0 as? String } }
    if let single = any as? String { return [single] }
    return nil
}

// MARK: - tool execution

func summaryLine(_ response: [String: Any]) -> String {
    let path = response["path"] as? String ?? "(no file)"
    let tier = response["tier"] as? String ?? "?"
    let requested = response["tier_requested"] as? String
    let steps = intValue(response["steps"])
    let width = intValue(response["width"])
    let height = intValue(response["height"])
    let seed = intValue(response["seed"])
    let seconds = doubleValue(response["seconds"])
    var parts: [String] = []
    if let width, let height { parts.append("\(width)x\(height)") }
    parts.append("tier \(tier)")
    if let requested, requested != tier { parts.append("asked for \(requested), not installed") }
    if let steps { parts.append("\(steps) steps") }
    if let seconds { parts.append(String(format: "%.1fs", seconds)) }
    if let seed {
        // "random" is worth saying out loud: it is the difference between a result
        // that can be reproduced exactly and one that merely looks similar.
        parts.append((response["seed_source"] as? String) == "random"
            ? "seed \(seed) (random)" : "seed \(seed)")
    }
    if let negative = response["negative"] as? String, !negative.isEmpty {
        parts.append("negative \"\(negative)\"")
    }
    var line = "Wrote \(path) [" + parts.joined(separator: ", ") + "]"
    if let metadata = response["metadata"] as? String {
        line += " + \(URL(fileURLWithPath: metadata).lastPathComponent)"
    }
    return line
}

func textBlock(_ text: String) -> [String: Any] { ["type": "text", "text": text] }

func failure(_ message: String, tool: String) -> [String: Any] {
    var content: [[String: Any]] = [textBlock(message)]
    if !tool.isEmpty { content[0]["text"] = "\(tool): \(message)" }
    var result: [String: Any] = ["content": content, "isError": true]
    if modernEnvelope { result["resultType"] = "complete" }
    return result
}

func inlineImageBlock(_ path: String) -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return ["type": "image", "data": data.base64EncodedString(), "mimeType": "image/png"]
}

func runTool(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
    var payload: [String: Any]
    var inlineThumbnail = false

    switch name {
    case "generate_image":
        guard let prompt = arguments["prompt"] as? String, !prompt.isEmpty else {
            return failure("prompt is required", tool: name)
        }
        payload = ["cmd": "generate", "prompt": prompt]
        for key in ["tier", "width", "height", "steps", "cfg", "seed", "negative"] {
            if let value = arguments[key] { payload[key] = value }
        }
        inlineThumbnail = boolValue(arguments["inline_thumbnail"]) ?? false

    case "edit_image":
        guard let prompt = arguments["prompt"] as? String, !prompt.isEmpty else {
            return failure("prompt is required", tool: name)
        }
        guard let images = stringList(arguments["images"]), !images.isEmpty else {
            return failure("images[] with at least one absolute path is required", tool: name)
        }
        payload = ["cmd": "edit", "prompt": prompt, "images": images]
        for key in ["tier", "width", "height", "target_pixels", "steps", "cfg", "img_cfg", "seed"] {
            if let value = arguments[key] { payload[key] = value }
        }
        inlineThumbnail = boolValue(arguments["inline_thumbnail"]) ?? false

    case "describe_image":
        guard let images = stringList(arguments["images"]), !images.isEmpty else {
            return failure("images[] with at least one absolute path is required", tool: name)
        }
        payload = [
            "cmd": "vqa",
            "prompt": (arguments["prompt"] as? String) ?? "Describe this image in detail.",
            "images": images,
        ]
        for key in ["think", "max_tokens", "tier"] {
            if let value = arguments[key] { payload[key] = value }
        }

    case "model_status":
        payload = ["cmd": "status"]

    case "model_options":
        payload = ["cmd": "options"]

    case "unload_model":
        payload = ["cmd": "unload"]

    default:
        return failure("unknown tool '\(name)'", tool: "")
    }

    let response: [String: Any]
    do {
        response = try daemon.call(payload)
    } catch {
        return failure("local image service unavailable: \(error)", tool: name)
    }
    guard (response["ok"] as? Bool) != false else {
        return failure("\((response["error"] as? String) ?? "unknown daemon error")", tool: name)
    }

    var result: [String: Any] = ["isError": false]
    if modernEnvelope { result["resultType"] = "complete" }
    var content: [[String: Any]] = []

    switch name {
    case "generate_image", "edit_image":
        content.append(textBlock(summaryLine(response)))
    case "describe_image":
        let answer = (response["text"] as? String) ?? ""
        let seconds = doubleValue(response["seconds"]).map { String(format: "%.1fs", $0) } ?? "?"
        content.append(textBlock("\(answer)\n\n[\(seconds) on the local SenseNova-U1.5 model]"))
    case "model_options":
        let options = (response["options"] as? [String: Any]) ?? [:]
        let sizes = (options["sizes"] as? [String: Any]) ?? [:]
        let steps = (options["steps"] as? [String: Any]) ?? [:]
        let cfg = (options["cfg"] as? [String: Any]) ?? [:]
        let tiers = (options["tiers"] as? [String: Any]) ?? [:]
        let sidecar = (options["sidecar"] as? [String: Any]) ?? [:]
        let recommended = (sizes["recommended"] as? [[String: Any]] ?? []).map {
            "\(intValue($0["width"]) ?? 0)x\(intValue($0["height"]) ?? 0) (\(($0["label"] as? String) ?? ""))"
        }.joined(separator: ", ")
        let available = ((tiers["available"] as? [String]) ?? []).joined(separator: ",")
        content.append(textBlock("""
        sizes: multiples of 32, \(intValue(sizes["minimum"]) ?? 0)...\(intValue(sizes["maximum"]) ?? 0); recommended \(recommended)
        steps: \(intValue(steps["minimum"]) ?? 1)...\(intValue(steps["maximum"]) ?? 500) (fast \(intValue(steps["fast_default"]) ?? 8), quality \(intValue(steps["quality_default"]) ?? 50)); cfg fast \(doubleValue(cfg["fast_default"]) ?? 1.0) / quality \(doubleValue(cfg["quality_default"]) ?? 4.0)
        seed: reproducible — same seed, same artifact, same settings writes the same bytes
        negative: generate_image only; edit_image rejects it
        sidecar: \((sidecar["enabled"] as? Bool) == true ? "on" : "off") — <image>.png.json (prompt + sha256, seed, size, steps, cfg, tier, artifact, seconds)
        tiers: available=\(available.isEmpty ? "none" : available) resident=\((tiers["resident"] as? String) ?? "cold")
        cancel: not supported — a dispatched request finishes and writes its PNG even if the client disconnects
        output_dir: \((options["output_dir"] as? String) ?? "?")
        """))
        result["content"] = content
        result["structuredContent"] = options
        return result
    case "model_status":
        let status = (response["status"] as? [String: Any]) ?? [:]
        let resident = (status["resident_tier"] as? String) ?? "cold"
        let installed = ((status["available_tiers"] as? [String]) ?? []).joined(separator: ",")
        let loads = intValue(status["loads_total"]) ?? 0
        let inflight = intValue(status["inflight"]) ?? 0
        let queued = intValue(status["queue_depth"]) ?? 0
        let ttl = intValue(status["ttl_seconds"]) ?? 0
        let peak = intValue(status["last_peak_mb"]) ?? 0
        content.append(textBlock("""
        resident_tier=\(resident) available_tiers=\(installed.isEmpty ? "none" : installed) \
        loads_total=\(loads) inflight=\(inflight) queue_depth=\(queued) \
        ttl_seconds=\(ttl) last_peak_mb=\(peak)
        \(status["current"] == nil ? "" : "current=" + ((status["current"] as? [String: Any]).map { current in
            "\(current["tool"] as? String ?? "job") step \(intValue(current["step"]) ?? 0)/\(intValue(current["total"]) ?? 0) \(intValue(current["percent"]) ?? 0)% elapsed \(doubleValue(current["elapsed_seconds"]) ?? 0)s"
        } ?? ""))
        """))
        result["content"] = content
        result["structuredContent"] = status
        return result
    case "unload_model":
        content.append(textBlock("released \(response["unloaded"] as? String ?? "none"); resident_tier=cold"))
        result["content"] = content
        result["structuredContent"] = response
        return result
    default:
        break
    }

    if inlineThumbnail, let path = response["path"] as? String, let block = inlineImageBlock(path) {
        content.append(block)
    }
    result["content"] = content
    result["structuredContent"] = response
    return result
}

// MARK: - JSON-RPC plumbing

func capabilities() -> [String: Any] {
    ["tools": ["listChanged": false]]
}

func serverInfo() -> [String: Any] {
    ["name": serverName, "title": serverTitle, "version": serverVersion]
}

func writeMessage(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else {
        log("could not serialize a response")
        return
    }
    var out = data
    out.append(0x0A)
    FileHandle.standardOutput.write(out)
}

func reply(id: Any, _ result: [String: Any]) {
    var envelope = result
    if modernEnvelope { envelope["resultType"] = "complete" }
    writeMessage(["jsonrpc": "2.0", "id": id, "result": envelope])
}

func replyError(id: Any, code: Int, _ message: String) {
    writeMessage(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

func handle(_ message: [String: Any]) {
    let method = message["method"] as? String ?? ""
    let params = (message["params"] as? [String: Any]) ?? [:]

    // Notifications carry no id and never get a response.
    guard let id = message["id"] else {
        switch method {
        case "notifications/initialized", "notifications/cancelled", "notifications/progress",
             "notifications/roots/list_changed":
            return
        default:
            log("ignoring notification \(method)")
            return
        }
    }

    switch method {
    case "initialize":
        let requested = params["protocolVersion"] as? String ?? legacyRevision
        let negotiated = supportedRevisions.contains(requested) ? requested : legacyRevision
        if negotiated == latestRevision { modernEnvelope = true }
        reply(id: id, [
            "protocolVersion": negotiated,
            "capabilities": capabilities(),
            "serverInfo": serverInfo(),
            "instructions": serverInstructions,
        ])

    case "server/discover":
        modernEnvelope = true
        reply(id: id, [
            "resultType": "complete",
            "supportedVersions": supportedRevisions,
            "capabilities": capabilities(),
            "serverInfo": serverInfo(),
            "instructions": serverInstructions,
            "ttlMs": listTTLms,
            "cacheScope": "private",
        ])

    case "ping":
        reply(id: id, [:])

    case "tools/list":
        var result: [String: Any] = ["tools": toolCatalogue]
        if modernEnvelope {
            result["ttlMs"] = listTTLms
            result["cacheScope"] = "private"
        }
        reply(id: id, result)

    case "tools/call":
        guard let name = params["name"] as? String else {
            replyError(id: id, code: -32602, "tools/call requires a tool name")
            return
        }
        let arguments = (params["arguments"] as? [String: Any]) ?? [:]
        reply(id: id, runTool(name, arguments))

    case "prompts/list":
        reply(id: id, ["prompts": []] as [String: Any])

    case "resources/list":
        reply(id: id, ["resources": []] as [String: Any])

    case "resources/templates/list":
        reply(id: id, ["resourceTemplates": []] as [String: Any])

    default:
        replyError(id: id, code: -32601, "Method not found: \(method)")
    }
}

// MARK: - stdio loop

signal(SIGPIPE, SIG_IGN)
log("ready (socket \(socketPath))")

var stdinBuffer = Data()
var chunk = [UInt8](repeating: 0, count: 64 * 1024)
while true {
    let n = read(0, &chunk, chunk.count)
    if n <= 0 { break }
    stdinBuffer.append(contentsOf: chunk[0..<n])
    while let newline = stdinBuffer.firstIndex(of: 0x0A) {
        let line = stdinBuffer.subdata(in: stdinBuffer.startIndex..<newline)
        stdinBuffer.removeSubrange(stdinBuffer.startIndex...newline)
        guard !line.isEmpty else { continue }
        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            writeMessage([
                "jsonrpc": "2.0", "id": NSNull(),
                "error": ["code": -32700, "message": "Parse error"],
            ])
            continue
        }
        handle(message)
    }
}
log("stdin closed, exiting")
