---
name: resource-download
description: Stage of a paper-reproduction pipeline, run from inside a cloned paper codebase after experiment-scoping has produced .paper-reproduction/experiment-scoping.md. Use whenever the task is to fetch, download, or pre-stage the datasets and checkpoints an experiment plan needs, or to check whether the available hardware (VRAM/RAM/disk) can support the planned experiments. Do not use for scoping experiments from the paper, setting up conda/pip environments, or executing and debugging experiment runs.
---

# resource-download

Turn a scoping report's asset list into real files on disk: verify the hardware can support
each experiment, download what is needed, and record an absolute path for every asset.

## Position in the pipeline

This is stage 2 of a reproduction pipeline:

- **experiment-scoping** (stage 1) produced `.paper-reproduction/experiment-scoping.md`,
  which lists per experiment: a command, the datasets/checkpoints it needs, and often sizes
  or parameter counts.
- **environment-setup** (stage 3) and **code-fix** (stage 4) consume *your* output: they
  substitute the absolute paths you record into stage 1's commands mechanically (replacing
  `<DATA_DIR>`/`<CKPT_DIR>`-style placeholders) and then run them.

So your report must be *mechanically actionable*: every path you record must be absolute,
must actually exist on disk (verified, not assumed), and must be tied back to the exact
placeholder or asset name stage 1 used. A wrong or hypothetical path breaks every
downstream stage in a way that is expensive to debug later.

## Inputs

- **The scoping report** at `.paper-reproduction/experiment-scoping.md`, relative to the
  repo root (the current working directory or the directory the user points at). If it does
  not exist, say so and stop — do not re-derive the asset list from the paper or the code
  yourself; that is stage 1's job, and silently redoing it would hide that the pipeline is
  being run out of order.
- **Hardware information.** If the user supplies it (they may be preparing assets for a
  different machine), use theirs and say so. Otherwise probe the current machine:
  - GPUs and VRAM: `nvidia-smi --query-gpu=name,memory.total --format=csv` (treat a missing
    `nvidia-smi` as "no GPU", not as an error).
  - System RAM: `free -g`.
  - Free disk: `df -h` on the filesystem where downloads will land (both the repo and any
    cache directory you will write to — they can be on different mounts).

  Record in the output what was probed vs. user-provided, so a later reader knows which
  machine the feasibility verdicts apply to.

## Process

### 1. Parse the scoping report

Collect, per experiment: its name, its "Datasets needed" and "Checkpoints needed" entries,
any stated sizes/parameter counts, and any notes the report addressed to stage 2 (scoping
reports often end with a summary of what stage 2 must do — read it, it encodes intent that
individual entries may not).

Deduplicate assets shared across experiments; an asset is downloaded once and mapped
everywhere it is used.

### 2. Check hardware feasibility — per experiment, before downloading anything

The point of checking first is to avoid wasting tens of GB of bandwidth and disk on weights
that can never be loaded. For each experiment that needs a checkpoint:

- Establish the checkpoint's size. Prefer, in order: a size/param count stated in the
  scoping report; the actual file listing at the source (e.g. the Hugging Face model page /
  `hf` API shows exact weight-file sizes); a param-count-based estimate. Do not guess when
  the source can tell you exactly.
- Compare against VRAM with a stated rule of thumb: fp16/bf16 inference needs roughly
  2 bytes per parameter plus ~20% overhead for activations; training needs several times
  that (optimizer states + gradients ≈ 4× weights for Adam). Use the mode the experiment
  actually runs in (a scoping report's mock command usually reveals whether it trains or
  only evaluates). Show the arithmetic in the report — a verdict without numbers cannot be
  audited.
- Also check total download size against free disk, with headroom.

Verdicts are **per experiment**: an infeasible experiment is marked SKIPPED with the
arithmetic that disqualified it, its exclusive assets are not downloaded, and the remaining
experiments proceed. Only if *no* experiment is feasible do you stop entirely — and even
then, write the report first so the pipeline records *why* it stopped rather than dying
silently.

Experiments that need no checkpoint (training small models from scratch) are feasible by
default unless the report flags something else (e.g. a dataset larger than free disk).

### 3. Download, with the hybrid storage policy

Where a file goes is determined by who will look for it:

- **Assets the experiment code auto-downloads** (keras/torchvision/HF `datasets` caches):
  pre-seed the exact cache path the loader checks, by fetching the same file from its
  canonical URL — e.g. keras MNIST is `~/.keras/datasets/mnist.npz` from
  `https://storage.googleapis.com/tensorflow/tf-keras-datasets/mnist.npz`. Pre-seeding
  makes later stages deterministic and offline-safe, and you do *not* need to install the
  framework just to trigger its downloader — a plain HTTP fetch to the right path is
  equivalent and much cheaper. If the file is already in the cache, verify it and record it
  as "already present" instead of re-downloading.
- **Everything else** (checkpoints named by hub id or URL, manually-hosted datasets): store
  under `<repo>/.paper-reproduction/assets/checkpoints/` and
  `<repo>/.paper-reproduction/assets/datasets/`, one subdirectory per asset. This keeps
  reproduction artifacts in one predictable place that later stages (and the user) can find
  and clean up.

Practical fetching guidance:

- Hugging Face models: `hf download <repo_id> --local-dir <target>` (older installs:
  `huggingface-cli download`), or `huggingface_hub.snapshot_download` from Python. If
  neither is available, fall back to direct `https://huggingface.co/<repo_id>/resolve/main/<file>`
  URLs with curl. Download the weights and the config/tokenizer files the experiment will
  load; skip formats the experiment does not use when the repo ships duplicates (e.g. don't
  pull both `.bin` and `.safetensors`, or TF/flax weights for a PyTorch experiment) — note
  what you skipped.
- Hugging Face datasets: `hf download <id> --repo-type dataset --local-dir <target>`, or
  the canonical source URL the scoping report gives.
- Plain URLs: `curl -L` / `wget`, into the assets directory.
- Assets you cannot fetch on the first attempt (gated, registration-walled, dead link):
  do **not** silently give up — follow the escalation loop in the next section.
  Never record a path you did not actually create.

### 3b. Hard-to-access assets: escalate to the user, don't give up

Some datasets and checkpoints cannot be fetched by a script: they sit behind a license
form, a registration page, an email request, or an expiring signed URL. For these, the
skill's contract is: **exhaust your own options first, then work the problem *with* the
user across as many turns as it takes. An asset is abandoned only when the user clearly
says it cannot be obtained.**

**First, try everything you can do alone.** Before involving the user, attempt every
autonomous route: the canonical source, official mirrors, the same dataset under a
different name on Hugging Face / Kaggle / academic hosting, download scripts shipped in the
repo itself, and archived copies of a dead link. Do not ask the user to do something a
different URL would have solved.

**Then pause and hand the user a concrete task.** When the remaining obstacle requires a
human (fill a form, accept a license, create an account, request access by email), stop and
ask — but first finish downloading all *other* assets, so one blocked asset never stalls
the rest. Batch the blocked assets into one request if there are several. The request must
be specific enough to act on without research:

- the exact URL of the form/portal and which option or license to choose;
- what artifact to bring back — a token, an approved account, a download link, or the
  file itself — and where to paste or put it;
- if they should download the file themselves: the exact **absolute destination path**
  (create the parent directory first so it exists when they get there), e.g.
  "place the archive at `<repo>/.paper-reproduction/assets/datasets/<name>/<file>`".

**Iterate — this is usually multi-turn.** Whatever the user comes back with, take the next
step yourself and report what happened:

- They provide a token/credentials → retry the authenticated download yourself
  (`hf auth login --token`, `curl -H "Authorization: ..."`, etc.).
- They provide a download link → try to fetch it. Signed/browser-session URLs often fail
  from curl even when they work in a browser; if the fetch fails, say exactly how it failed
  and fall back to asking them to download it in their browser and drop the file at the
  absolute path you prepared.
- They placed a file manually → verify it exactly as in step 4 (exists, plausible size,
  archive opens) before accepting it, and record it as "provided manually by user".
- Something still fails → diagnose, propose the next-cheapest step for them, and ask again.
  Each round should shrink the problem; never re-ask for something they already gave you.

**Stop only on the user's clear signal.** Mark an asset BLOCKED only when the user states
it is impossible or not worth obtaining ("we can't get access", "skip that dataset"). Then
record the verdict, the escalation history in brief, and continue with the experiments that
don't need it — per-experiment feasibility from step 2 applies as usual. Ambiguous or
absent answers are not a signal to give up; ask again or leave the question pending in your
final message, with everything else in the report already complete.

### 4. Verify every download

For each asset, after fetching: confirm the file(s) exist at the recorded path, compare
size on disk against the expected size when one is known (a truncated download "succeeds"
in curl more often than you'd hope), and spot-check that archives open (`tar -tf`,
`unzip -l`, or a magic-bytes check for `.npz`/`.safetensors`). Record the verified size.
The contract is simple: **if a path appears in your report, `ls` on that path works.**

## Output format

ALWAYS use this exact structure, saved to `.paper-reproduction/resource-download.md` under
the repo root:

`````markdown
# Resource Download Report

## Hardware
- Source: probed on this machine / provided by user
- GPU: <name>, <N> GB VRAM (or "none")
- RAM: <N> GB; free disk: <N> GB on <mount>

## Feasibility
| Experiment | Verdict | Reason |
|---|---|---|
| Exp 1: <name> | FEASIBLE | no checkpoint; trains small model from scratch |
| Exp 2: <name> | SKIPPED | 20B params ≈ 40 GB fp16 + overhead > 24 GB VRAM (arithmetic shown below) |

Show the arithmetic for every SKIPPED verdict.

## Assets
### <asset name, as stage 1 named it>
- **Path:** /absolute/path/to/asset
- **Size on disk:** <verified size>
- **Obtained:** downloaded from <source> / pre-seeded cache from <URL> / already present / provided manually by user (verified) / BLOCKED: user confirmed unobtainable — <what was tried, in one line>
- **Used by:** Exp 1, Exp 3

## Placeholder mapping
| Placeholder in scoping command | Absolute path |
|---|---|
| `<CKPT_DIR>/gpt2` | /home/user/repo/.paper-reproduction/assets/checkpoints/gpt2 |
| `<DATA_DIR>/e2e` | /home/user/repo/.paper-reproduction/assets/datasets/e2e |

## Notes
Anything downstream stages should know: skipped duplicate weight formats, cache paths that
depend on $HOME, assets that auto-download at runtime anyway, blocked assets, and any
asset still pending user action (with exactly what the user was asked to do).
`````

If the scoping report used no placeholders (e.g. all data is generated in-process or
auto-downloaded), keep the "Placeholder mapping" section with a single line saying so —
downstream stages look for the section, not for your prose.

## Boundaries

- This skill checks feasibility and moves bytes. It does not create environments, install
  ML frameworks, run any experiment command, or fix code.
- Install nothing beyond what downloading itself needs (e.g. it is fine to `pip install
  huggingface_hub` into user space if no fetch route exists; it is not fine to install
  torch/tensorflow "while you're at it" — that is stage 3's job, and version choices made
  casually here would conflict with its lockfile-first policy).
- Download only what the scoping report names. If you believe the report missed an asset,
  record that under Notes — do not unilaterally expand the plan.
- Pausing mid-stage to ask the user for manual access steps (section 3b) is normal
  operation, not a failure. BLOCKED is reserved for assets the user has explicitly given
  up on — never for assets you simply have not managed to fetch yet.
