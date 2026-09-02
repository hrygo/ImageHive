# Pose specialty — gate receipts (2026-09-02, M5 Max)

Gates for the `pose-8bit` / `pose-bf16` tiers added in v0.4.0. Every one of them
is written so it **can fail**, and two of them are shown failing on purpose
below (AB-L-0026).

> The images in this directory are **CC BY-SA 4.0** adaptations of a Wikimedia
> Commons video, not MIT like the rest of the repository — credits and terms in
> [`NOTICE.md`](NOTICE.md).

Adapter: `refcontrol-pose-sensenova/pose_lora_003000.safetensors` — v1 @ 3000
steps, `neo_hf_lora`, rank 32 / alpha 32, 294 `*_mot_gen` targets, trained by
ltx-studio on `SenseNova-U1.5-8B-MoT-SFT` and merged here into the **final**
serving checkpoint. `applyLoRA` merges 294/294.

---

## (a) A zero-B adapter through `--convert` is a no-op

A copy of the pose adapter with every `lora_up` (the B factor) forced to zero
and `lora_down` / `alpha` left at their real values, so the merge does all of
its real matmuls and must still add exactly nothing.

```bash
sensenova-cli --weights <HF base> --quant 8 --convert /tmp/plain-8bit
sensenova-cli --weights <HF base> --lora zero_b_lora.safetensors --quant 8 --convert /tmp/zerob-8bit
sensenova-cli --diff-artifacts /tmp/plain-8bit --diff-artifacts /tmp/zerob-8bit
```

```
[diff] compared 2292 tensors
[diff] IDENTICAL — every tensor matches byte-for-byte
```

**The same gate, failing, on the real adapter** (the negative control — a gate
that cannot go red is a notification):

```
$ sensenova-cli --diff-artifacts SenseNova-U1.5-8B-MoT-8bit \
                --diff-artifacts SenseNova-U1.5-8B-MoT-pose-8bit
[diff] compared 2292 tensors
[diff] 882 DIFFERENCE(S):
[diff]   …layers.0.mlp_mot_gen.down_proj.biases: differs (max |Δ| 0.70703125)
[diff]   …layers.0.mlp_mot_gen.down_proj.scales: differs (max |Δ| 0.0055236816)
[diff]   …layers.0.mlp_mot_gen.down_proj.weight: differs (6782118/50331648 packed bytes)
   …
exit 1
```

882 = 294 targets × {weight, scales, biases}. Nothing outside the adapter's
target set moved — the merge is exactly as wide as the adapter claims to be.

> ⚠ **`shasum` is not the test here, and this is the finding worth carrying.**
> `saveArtifact` hands MLX a Swift `Dictionary`, and `mlx_save_safetensors`
> writes whatever order that unordered map iterates in — which is randomized per
> process. Two converts of *identical* weights therefore produce shards with
> identical `weight_map` entries, identical tensor contents, and **different
> file hashes**. The first run of this gate "failed" on shard hashes for exactly
> that reason. `--diff-artifacts` compares tensor content keyed by name, which is
> the property that actually matters, and it is what the gate asserts.

The freshly built `SenseNova-U1.5-8B-MoT-pose-8bit` is also byte-for-byte
identical to `refcontrol-pose-sensenova/artifacts/pose-3000-8bit`, the artifact
AB-R-0194 rendered its int8 verdict on — so that verdict transfers to what we
would publish.

## (b) Swapping the two reference slots degrades the render

`bboyairchair_000000` (a valid pose fixture — svilpaite and mohedano are not,
AB-R-0196). 768², 28 steps, cfg 4, seed 42, `pose-8bit`.

| file | slot 1 | slot 2 |
|---|---|---|
| `pose-correct.png` | `input-1-skeleton.png` | `input-2-identity.jpg` |
| `pose-swapped.png` | `input-2-identity.jpg` | `input-1-skeleton.png` |

**Correct order:** the man from the identity frame is restaged — standing,
leaning, one leg extended, at the skeleton's position and scale, in the same
club scene, wearing the same white shirt. The pose comes from image 1 and the
appearance from image 2, which is what the tier is for.

**Swapped:** the render is essentially the identity frame again — the subject
stays face-down on the floor in the reference's own pose and the skeleton is
ignored. The transfer does not happen.

Backing the eyeball with a number, distance from each render to the identity
reference:

| render | MAE vs identity | PSNR vs identity |
|---|---|---|
| correct order | 11.82 | 20.59 dB |
| swapped | 5.72 | 26.14 dB |

The swapped render sits **5.5 dB closer to the reference photo** — it is close
to a copy of it, rather than a restaging of it. (Read the direction carefully:
"closer to the reference" is the *failure* signature here, not better identity
preservation. The correct render has to move the subject, so it must be
further away.)

## (c) The existing suites stay green

```
Executed 21 tests, with 0 failures   # SenseNovaU1Tests   (component / e2e / edit parity, artifact round-trip)
Executed 15 tests, with 0 failures   # MLXSenseNovaU1Tests (manifest, provenance split, MAT, CAN, + 4 new pose gates)
```

Nine of the wrapper tests are the conformance set; four are new and cover the
pose tier: every surface stays enabled on a merge tier, the specialty is a
**registered** C6 term scoped to the pose variants only, the pose registration
refuses a non-pose configuration, and the two-slot prompt survives the
placeholder expander with exactly two images.

The parity suites read their fixtures from paths relative to the repo root, so
in a git **worktree** they need the env overrides:

```bash
O=/Volumes/Satechi/Development/mlxengine-image/WIP/sensenova-u1-oracle
SENSENOVA_FIXTURES=$O/fixtures/components \
SENSENOVA_T2I_FIXTURES=$O/fixtures/t2i_256x256_s4_bf16 \
SENSENOVA_EDIT_FIXTURES=$O/fixtures/edit_512x512_s4_bf16 \
SENSENOVA_WEIGHTS=/Volumes/Satechi/Development/mlxengine-image/weights/SenseNova-U1.5-8B-MoT \
swift test
```

## (d) Live wrapper smoke on the pose tier

`LivePackageTests.testLivePoseEditTwoReference` — the package API, not the CLI:
`IEditRequest(images: [skeleton, identity], prompt: SenseNovaVariant.posePrompt)`
on `.pose8`, plus the swapped pair.

```bash
SENSENOVA_LIVE_PKG=1 SENSENOVA_ARTIFACTS=<artifacts root> \
  swift test --filter testLivePoseEditTwoReference
```

```
Test Case '…testLivePoseEditTwoReference' passed (63.961 seconds)
  [live] pose edit: 825920 vs swapped 847819 bytes
```

`wrapper-pose-correct.png` is **pixel-identical** to the CLI's
`pose-correct.png` (PSNR ∞, MAE 0.000) — the wrapper and the CLI are the same
render path, and the multi-image plumbing added to the CLI does not diverge
from what the engine drives. The two PNG files differ in size only because
CoreGraphics and PIL encode PNG differently.

## Cost

| step | wall | peak GPU |
|---|---|---|
| int8 `--convert` (per artifact) | ~25 s | — |
| bf16 `--convert` | ~30 s | — |
| `--diff-artifacts` on two int8 artifacts | 4.6 s | — |
| 768² 28-step two-reference edit, `pose-8bit` | 20.2 s (0.72 s/step) | 22.5 GB |
| artifact load, `pose-8bit` | 2.6 s | 19.0 GB resident |

The 20 s / 22.5 GB figures reproduce ltx-studio's 18–20 s at 23 GB from the C0
run — the tier behaves the same through the port's own CLI and through the
wrapper.
