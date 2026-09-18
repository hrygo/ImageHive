# Model artifacts

An *artifact* is a directory the daemon can hand straight to MLX: `config.json`,
one or more `model-*.safetensors` shards plus their index, `tokenizer.json` and
the usual tokenizer side files. Nothing is converted at install time — the
artifacts below are published ready to run, tokenizer included.

## Presets

| Preset | Repository | Disk | Peak RAM | Tier | Use it for |
|---|---|---|---|---|---|
| `fast-4bit` | `mlx-community/SenseNova-U1.5-8B-MoT-8step-4bit` | 11 GiB | ~15 GB | fast | drafts and iteration; the install default |
| `fast-8bit` | `mlx-community/SenseNova-U1.5-8B-MoT-8step-8bit` | 20 GiB | ~22 GB | fast | closer to the bf16 draw, still cfg-free and quick |
| `quality-bf16` | `mlx-community/SenseNova-U1.5-8B-MoT-bf16` | 33 GiB | ~35 GB | quality | 50-step quality, text rendering, editing, VQA |

```bash
sensenova-u1 models                          # installed / not installed
sensenova-u1 models pull fast-4bit           # ModelScope first, Hugging Face fallback
sensenova-u1 models pull quality-bf16 hf     # force a source
sensenova-u1 models pull all                 # everything (48 GiB+)
sensenova-u1 models verify                   # sizes on disk vs the download manifest
```

## Image sizes

`width` and `height` are pixels, and both must be **multiples of 32**, from 32 to
4096. That is not a policy but the latent grid: the tower patches at 16 px and
downsamples by 0.5, so one token covers 32 px and the image is cut into a
`size/32` grid. A value that does not divide is refused before any weights are
loaded, and the message names legal values to use instead.

| Shape | Size |
|---|---|
| square 1:1 | 1024×1024 |
| landscape 3:2 | 1216×832 |
| landscape 16:9 | 1600×896 |
| portrait 9:16 | 896×1600 |

1024×1024 is the default when a request names no size, and the reference point
for comparisons. `sensenova-u1 options` prints this table in a terminal and
`model_options` returns it as JSON, so a client can read the contract up front
instead of discovering it from a rejection.

Cost scales with pixel count. Measured on an M5 Max with the quality artifact at
50 steps: 1024×1024 took ~50 s and 1536×1024 took ~71 s. Larger canvases are
proportionally slower; the daemon makes no claim about how they look, only that
they take longer.

## Sources

Download happens with `curl` and resumes (`-C -`), so an interrupted run costs
only the bytes that are missing.

* **ModelScope** (default, `auto`): the `mlx-community/*` artifacts are mirrored
  there and download directly without a proxy — the right choice from China.
* **Hugging Face** (`hf`): used automatically when ModelScope does not have the
  repository. Set `HF_ENDPOINT=https://hf-mirror.com` to use the public mirror.

## Choosing by memory

| Unified memory | Recommendation |
|---|---|
| 18–24 GB | `fast-4bit` only, and keep other heavy apps closed |
| 32–48 GB | `fast-4bit` + `quality-bf16`, but not both resident at once (the daemon keeps one) |
| 64 GB+ | both tiers comfortably; raise `ttl_seconds` if you want to stay warm |

The daemon holds **one** tier at a time: asking for the other tier releases the
first. `sensenova-u1 status` shows `resident_tier`, `last_peak_mb` and
`loads_total`.

## One artifact is enough

A machine only needs one of the two artifacts. Both are installed by the same
machinery and both serve every tool, so which one a machine keeps is a
disk-and-quality decision, not a capability one:

* a small machine installs `fast-4bit` (11 GiB) and skips the bf16 artifact;
* a roomy machine installs `quality-bf16` and skips the distilled one.

When a request names a tier whose artifact is not installed, the daemon serves it
from the artifact that is, and the reply names both:

```
tier quality, asked for fast, not installed, 50 steps
```

The **recipe follows the artifact that runs**, never the request: the distilled
weights are only ever driven at 8 steps with cfg 1.0, the bf16 weights at 50
steps with cfg 4.0 (an explicit `steps` / `cfg` still wins, as always). A
fallback therefore cannot quietly produce an out-of-distribution image, it can
only produce the best image the installed artifact knows how to make.

Where to see it: `model_status` (and `sensenova-u1 status`) report
`available_tiers`; `sensenova-u1 models` prints each tier's directory and
whether it is installed; `sensenova-u1 doctor` reports a missing artifact as a
note, not a failure. The daemon reads `config.json` once at startup, so after
adding or removing an artifact, `sensenova-u1 restart`.

## Using artifacts you already have

Point the daemon at any directory with the same shape:

```json
// ~/Library/Application Support/SenseNovaU1/config.json
{
  "ttl_seconds": 600,
  "min_warm_seconds": 60,
  "quality_artifact": "/absolute/or/relative/path/to/quality"
}
```

Both tier keys are optional and independent: name the artifact you installed,
leave the other one out (or pointing at a path that is not there) and the daemon
serves both tiers from the one it finds.

Relative paths resolve against the models root
(`~/Library/Application Support/SenseNovaU1/models` by default —
`sensenova-u1 paths` prints it, `SENSENOVA_MODELS` or `--models` moves it). This
is how a machine that built its own artifacts (for example a bf16 8-step merge
produced with the upstream `sensenova-cli convert`) can use them instead of
downloading a preset.

## Building your own artifact (advanced)

The upstream CLI in this repository can convert a Hugging Face checkpoint into a
runnable artifact and merge the 8-step distillation LoRA:

```bash
swift build -c release --product sensenova-cli
.build/release/sensenova-cli convert --weights /path/to/SenseNova-U1.5-8B-MoT --out my-artifact
```

The official checkpoint has no `tokenizer.json`; generate it once with
`AutoTokenizer.from_pretrained(<dir>, local_files_only=True).save_pretrained(<dir>)`
in any Python environment that has `transformers` and `tokenizers`, then copy it
into the artifact. Expect ~16 GB of extra disk for the converter's transient files.
