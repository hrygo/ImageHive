# Image credits and licence for this directory

The repository's MIT licence covers the **code**. It does **not** cover the six
image files in this directory, which are derived from third-party material.

| file | what it is |
|---|---|
| `input-2-identity.jpg` | a frame from *B-boy performing airchair spin in slow motion* |
| `input-1-skeleton.png` | an OpenPose-style skeleton extracted from another frame of the same video |
| `pose-correct.png`, `pose-swapped.png` | renders conditioned on those two images (`sensenova-cli`) |
| `wrapper-pose-correct.png`, `wrapper-pose-swapped.png` | the same two renders through the package API |

**Source work:** [*B-boy performing airchair spin in slow motion*](https://commons.wikimedia.org/wiki/File:B-boy_performing_airchair_spin_in_slow_motion.webm)
by **Grendelkhan**, Wikimedia Commons, licensed
[**CC BY-SA 4.0**](https://creativecommons.org/licenses/by-sa/4.0/).

**Changes made:** frames extracted from the video; one frame reduced to a pose
skeleton; the renders are model outputs conditioned on those frames.

**Licence of these six files:** [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/),
as adaptations of the source work.

They are the held-out **validation** subject of the pose corpus, which is
Wikimedia-Commons-only and publishable by construction. The corpus's *training*
split additionally contains Pexels-sourced frames: the Pexels License permits
training and forbids redistributing the frames, so those are **train-only** and
are not reproduced anywhere in this repository. Trained weights are unaffected
by that restriction.
