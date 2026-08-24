// sensenova-cli — manual T2I runs for perf/eyeball work.
// Prompt ids come from .npy fixtures until the tokenizer artifact lands
// (tokenizer.json generation is on the spec's open-items list).
//
// Usage:
//   sensenova-cli --weights DIR --cond-ids cond.npy --uncond-ids uncond.npy \
//     --width 1024 --height 1024 --steps 20 --out out.npy [--seed 42]

import Foundation
import MLX
import SenseNovaU1

func arg(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: "--\(name)"), i + 1 < a.count else { return nil }
    return a[i + 1]
}

func loadIDs(_ path: String) throws -> [Int32] {
    try MLX.loadArray(url: URL(fileURLWithPath: path)).asType(.int32).asArray(Int32.self)
}

let weights = URL(fileURLWithPath: arg("weights") ?? "/Volumes/Satechi/Development/mlxengine-image/weights/SenseNova-U1.5-8B-MoT")
let width = Int(arg("width") ?? "1024")!
let height = Int(arg("height") ?? "1024")!
var params = T2IParams()
params.numSteps = Int(arg("steps") ?? "20")!
if let s = arg("seed") { params.seed = UInt64(s)! }
if let c = arg("cfg") { params.cfgScale = Float(c)! }
let outPath = arg("out") ?? "sensenova_out.npy"

let condIds = try loadIDs(arg("cond-ids")!)
let uncondIds = arg("uncond-ids").map { try! loadIDs($0) }

print("[cli] loading model bf16 ...")
var t0 = Date()
let model = try WeightLoading.load(from: weights, dtype: .bfloat16)
print("[cli] loaded in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
print("[cli] resident after load: \(GPU.activeMemory / (1 << 20)) MB active, peak \(GPU.peakMemory / (1 << 20)) MB")

t0 = Date()
let image = model.t2iGenerate(
    condIds: condIds, uncondIds: uncondIds, width: width, height: height,
    params: params
) { step, total in
    if step % 5 == 0 || step == total {
        let dt = Date().timeIntervalSince(t0)
        print("[cli] step \(step)/\(total)  \(String(format: "%.2f", dt / Double(step)))s/step  active \(GPU.activeMemory / (1 << 20)) MB")
    }
}
eval(image)
let wall = Date().timeIntervalSince(t0)
print("[cli] \(params.numSteps)-step \(width)x\(height): \(String(format: "%.1f", wall))s total, \(String(format: "%.2f", wall / Double(params.numSteps)))s/step")
print("[cli] peak memory: \(GPU.peakMemory / (1 << 20)) MB")

try MLX.save(array: image.asType(.float32), url: URL(fileURLWithPath: outPath))
print("[cli] wrote \(outPath)")
