# Publishing the pose artifacts — prepared, NOT pushed

Both artifacts are built, gated and staged locally. **Nothing has been uploaded.**
Pushing them is an outward action and needs the operator's go-ahead, and there is
one licence question below that has to be answered first.

Staged at `/Volumes/Satechi/Development/mlxengine-image/weights/artifacts/`:

| artifact | size | target repo |
|---|---|---|
| `SenseNova-U1.5-8B-MoT-pose-8bit` | 19.9 GB, 4 shards | `mlx-community/SenseNova-U1.5-8B-MoT-pose-8bit` |
| `SenseNova-U1.5-8B-MoT-pose-bf16` | 35.1 GB, 7 shards | `mlx-community/SenseNova-U1.5-8B-MoT-pose-bf16` |

## ⚠ Decide this before pushing: the training corpus, not the checkpoint

The base checkpoint is Apache-2.0 and the port is MIT — both clean. The **adapter**
is the open question. Its training split is 104 identities, of which **78 are
Pexels-sourced and marked train-only**: the Pexels License forbids redistributing
the photos and videos themselves, and the corpus docs state plainly that AI
training "is not addressed by the Pexels License (neither granted nor denied) —
fine for an internal LoRA; weigh before distributing weights trained on it."

Publishing these artifacts distributes **weights trained on that material**, which
is the exact case that note defers. This is AB-L-0082 territory: a permissive
checkpoint licence says nothing about the corpus. Three ways out, for the
operator to pick:

1. **Publish as-is** with the corpus composition stated on the card (the position
   that model weights are not a redistribution of the training images).
2. **Publish to `xocialize/` rather than `mlx-community/`** — same durability
   guarantee for our own `WeightSourcing`, without putting a corpus-ambiguous
   merge into the community namespace. (The variant's `repo` string changes with it.)
3. **Retrain on the Commons-only split** and publish that, keeping the
   Pexels-augmented adapter internal.

Nothing else about the tier is blocked by this — the artifacts work locally today
via `snapshotPath`.

## Card (identical for both, with the tier line swapped)

```markdown
---
license: apache-2.0
base_model: sensenova/SenseNova-U1.5-8B-MoT
library_name: mlx
tags: [mlx, image-to-image, image-editing, pose, lora-merged, apple-silicon]
---

# SenseNova-U1.5-8B-MoT-pose-8bit

A pose-transfer tier of [SenseNova-U1.5-8B-MoT](https://huggingface.co/sensenova/SenseNova-U1.5-8B-MoT)
for [sensenova-u1-swift](https://github.com/xocialize/sensenova-u1-swift) on Apple
silicon: the RefControl pose adapter merged into the base checkpoint, then
quantized to 8-bit (group 64) on the two transformer streams.

## What it does

Restages the person in a reference photo into the pose of an OpenPose-style
skeleton, keeping identity, clothing and scene. It is a **two-reference edit** and
the slot order matters:

```
Image-1: <image>
Image-2: <image>
apply pose from image 1 with reference from image 2
```

Image 1 is the skeleton, image 2 the identity/appearance frame. Swapping them makes
the model reproduce the appearance frame's own pose and ignore the skeleton.

```bash
sensenova-cli --weights SenseNova-U1.5-8B-MoT-pose-8bit \
  --edit-image skeleton.png --edit-image identity.jpg \
  --prompt $'Image-1: <image>\nImage-2: <image>\napply pose from image 1 with reference from image 2' \
  --width 768 --height 768 --steps 28 --cfg 4.0 --out posed.npy
```

768², 28 steps, cfg 4: **20.2 s at 22.5 GB peak** on an M5 Max; 2.6 s to load,
19.0 GB resident.

## Provenance

- Base: `sensenova/SenseNova-U1.5-8B-MoT` @ `07d76f61` (Apache-2.0). Hub `main`
  has since moved to `19bc874e`, a bf16 re-shard of the same weights; this
  artifact was converted from the pinned revision.
- Adapter: RefControl pose LoRA v1 @ 3000 steps — rank 32 / alpha 32, `neo_hf_lora`
  layout, 294 gen-stream (`*_mot_gen`) projections, trained on
  (skeleton, reference, target) triples. Merged in fp32 as `W += (alpha/rank)·BA`
  and cast, all 294 targets matched.
- Conversion: `sensenova-cli --weights <base> --lora <adapter> --quant 8 --convert <out>`.
- The merge is exactly as wide as the adapter claims: against the plain 8-bit
  artifact, 882 tensors differ — 294 targets × {weight, scales, biases} — and
  nothing else. A zero-B adapter through the same path reproduces the plain
  artifact tensor-for-tensor.

## Tier

8-bit reproduces the bf16 renders on all five valid held-out fixtures, so this is
the recommended tier; `-pose-bf16` exists for reference-precision work at 35.1 GB.

## Licence

Apache-2.0, following the base checkpoint. Port code is MIT.
```

## Upload

```bash
hf auth whoami
hf upload mlx-community/SenseNova-U1.5-8B-MoT-pose-8bit \
  /Volumes/Satechi/Development/mlxengine-image/weights/artifacts/SenseNova-U1.5-8B-MoT-pose-8bit \
  . --repo-type model
hf upload mlx-community/SenseNova-U1.5-8B-MoT-pose-bf16 \
  /Volumes/Satechi/Development/mlxengine-image/weights/artifacts/SenseNova-U1.5-8B-MoT-pose-bf16 \
  . --repo-type model
```

## After the upload — PUBLISHED-ARTIFACT VERIFIED

The staged bytes passing a gate is not evidence the published bytes do (the LaMa
lesson). Download the repo fresh into a throwaway directory and re-run the gate on
what came back:

```bash
hf download mlx-community/SenseNova-U1.5-8B-MoT-pose-8bit --local-dir /tmp/pose-verify
sensenova-cli --diff-artifacts \
  /Volumes/Satechi/Development/mlxengine-image/weights/artifacts/SenseNova-U1.5-8B-MoT-pose-8bit \
  --diff-artifacts /tmp/pose-verify
SENSENOVA_LIVE_PKG=1 SENSENOVA_ARTIFACTS=/tmp swift test --filter testLivePoseEditTwoReference
```

Then flip the `pose-8bit` row in the README's table to a hub link, and update the
registry row's availability.
