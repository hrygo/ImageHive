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

## Using artifacts you already have

Point the daemon at any directory with the same shape:

```json
// ~/Models/SenseNova-U1.5/config.json
{
  "ttl_seconds": 600,
  "min_warm_seconds": 60,
  "fast_artifact": "/absolute/or/relative/path/to/fast",
  "quality_artifact": "/absolute/or/relative/path/to/quality"
}
```

Relative paths resolve against `SENSENOVA_HOME`. This is how a machine that built
its own artifacts (for example a bf16 8-step merge produced with the upstream
`sensenova-cli convert`) can use them instead of downloading a preset.

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
