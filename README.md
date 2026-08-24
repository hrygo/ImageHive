# sensenova-u1-swift

Native Apple Silicon (MLX-Swift) port of **[SenseNova-U1.5-8B-MoT](https://huggingface.co/sensenova/SenseNova-U1.5-8B-MoT)** — SenseTime's unified multimodal flagship: text-to-image, instruction image editing, and visual question answering in one NEO-unify **Mixture-of-Transformers** model (8.1B understanding + 8.1B generation streams on a shared 42-layer Qwen3 skeleton, pixel-space rectified flow, **no VAE**).

All three capabilities run locally on a Mac:

- **Text-to-image** — up to the native 2048²-class trained buckets, 50-step base or 8-step distilled tier, optional `<think>` reasoning mode
- **Image editing** — identity-preserving instruction edits (`it2iGenerate`)
- **VQA / chat** — image-grounded question answering on the understanding stream

## Performance (M5 Max, prebuilt artifacts)

| Artifact | Peak memory | 1024² image | 2048² image |
|---|---|---|---|
| [`SenseNova-U1.5-8B-MoT-8step-4bit`](https://huggingface.co/mlx-community/SenseNova-U1.5-8B-MoT-8step-4bit) | **14.8 GB** | **3.2 s** | **15.8 s** |
| [`SenseNova-U1.5-8B-MoT-8step-8bit`](https://huggingface.co/mlx-community/SenseNova-U1.5-8B-MoT-8step-8bit) | 22.4 GB | 3.8 s | 19.5 s |
| [`SenseNova-U1.5-8B-MoT-8bit`](https://huggingface.co/mlx-community/SenseNova-U1.5-8B-MoT-8bit) | 22.9 GB | ~7.4 s (cfg 4) | — |
| [`SenseNova-U1.5-8B-MoT-bf16`](https://huggingface.co/mlx-community/SenseNova-U1.5-8B-MoT-bf16) | 35.1 GB | ~6.6 s (cfg 4) | ~40 s (cfg 4) |

`8step` artifacts have the official [8-step distillation LoRA](https://huggingface.co/xocialize/SenseNova-U1.5-8B-MoT-LoRAs) pre-merged and run **cfg-free** (single forward per step) — use them for fast T2I. Use `bf16`/`8bit` for 50-step quality T2I, **editing**, VQA, and think mode. Per the fleet quantization doctrine for diffusion paths, **8-bit reproduces the bf16 image (cos 0.998); 4-bit is a declared opt-in tier** that produces a different-but-equally-valid draw (cos ~0.92 at fixed seed).

## Quick start (CLI)

```bash
swift build -c release

# fast tier: 1024² in ~3 s
.build/release/sensenova-cli \
  --weights /path/to/SenseNova-U1.5-8B-MoT-8step-4bit \
  --prompt "A cinematic mountain lake at sunrise, realistic photography." \
  --width 1024 --height 1024 --steps 8 --cfg 1.0 --out out.npy

# quality tier + think mode
.build/release/sensenova-cli --weights /path/to/SenseNova-U1.5-8B-MoT-bf16 \
  --think --prompt "Minimalist poster for a jazz concert titled 'BLUE HOUR'" \
  --width 1024 --height 1024 --steps 50 --cfg 4.0 --out poster.npy

# instruction editing
.build/release/sensenova-cli --weights /path/to/SenseNova-U1.5-8B-MoT-bf16 \
  --edit-image photo.png \
  --prompt "Change the jacket to cobalt blue. Preserve the face, pose, and lighting." \
  --steps 50 --cfg 4.0 --out edited.npy

# VQA
.build/release/sensenova-cli --weights /path/to/SenseNova-U1.5-8B-MoT-bf16 \
  --vqa "Describe this image in one sentence." --edit-image photo.png
```

Outputs are `.npy` tensors in the model's normalized space (`x·0.5 + 0.5` → RGB); pipe through any converter or use the library API. The CLI also loads the original HF checkpoint directly (`--weights <hf-snapshot>` + optional `--quant 8|4` and `--lora <file>`), and `--convert OUTDIR` produces the prebuilt artifacts above.

## Library

```swift
import SenseNovaU1

let model = try WeightLoading.loadArtifact(from: artifactDir)   // or .load(from:) for HF checkpoints
let tok = try await SenseNovaTokenizer.load(from: artifactDir)
let (cond, uncond) = tok.t2iIDs(prompt: "A tabby cat on a red velvet chair")
var params = T2IParams()                    // 50 steps, cfg 4.0, shift 3.0 (reference defaults)
let image = model.t2iGenerate(condIds: cond, uncondIds: uncond,
                              width: 1024, height: 1024, params: params)
```

`it2iGenerate` (editing), `chat` (VQA), and `t2iGenerateThink` (reasoning mode) are the other entry points.

## Parity

The port is gated against the reference PyTorch implementation ([OpenSenseNova/SenseNova-U1](https://github.com/OpenSenseNova/SenseNova-U1) @ `a62fd54`, weights `07d76f6`):

- component parity (fp32, CPU stream): all ops < 1e-4, decoder layers at relative 1e-5 across both streams
- e2e bf16 vs the torch oracle: per-pass velocity cosine 0.999+; editing e2e at cos 0.9990 / 34.6 dB
- THW positional indexing exactly integer-equal; tokenizer ids exactly equal
- production-grid renders eyeball-gated at 1024² and 2048²

Oracle fixtures and capture harnesses live in the companion `sensenova-u1-oracle` workspace (spec: `PORTING-SPEC.md`, including a 21-item trap ledger — dual RoPE conventions, the `[::2]` frequency-range trick, fp32 gen-stream activations to 4.3e5, and more).

**Known workaround:** mlx-swift ≤ 0.31.6 JIT builds mis-instantiate the NAX split-K bf16 GEMM ([mlx#3797](https://github.com/ml-explore/mlx/issues/3797)); the FFN down-projection is row-chunked ≤896 rows on the bf16 path (exact; quantized tiers are unaffected). Removed automatically once a fixed mlx-swift release lands.

## License & provenance

- Port code: **MIT** (this repository)
- Model weights: **Apache-2.0** — SenseNova-U1.5-8B-MoT by [SenseTime / SenseNova](https://huggingface.co/sensenova) ([paper](https://arxiv.org/abs/2605.12500), [reference implementation](https://github.com/OpenSenseNova/SenseNova-U1)). The prebuilt artifacts above are format conversions (bf16 cast / group-64 quantization / official-LoRA merge) of the upstream checkpoint, redistributed under the same license with credit; original license text and provenance are stated on each artifact card.
