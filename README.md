# fedora-llamacpp

Podman-based deployment of `llama-server` (llama.cpp, ROCm gfx1151) running
Qwen3.8-27B-GGUF (UD-Q4_K_XL) on Strix Halo (Ryzen AI Max+ 395, 32GB UMA).

One container, three equivalent deployment methods. All three define the
**identical** container (name `llama-server`, port 8000, image, devices,
IPC, volumes, env) — keep them in sync. Run exactly one at a time:

| Method | File(s) | Start |
|---|---|---|
| podman run | `scripts/llama-server.sh` | `./scripts/llama-server.sh` (replaces running container) |
| podman compose | `podman-compose.yml` | `podman compose up -d` (recreates on change) |
| quadlet | `config/containers/systemd/llama-server/*.container`, `*.build` | copy into `/etc/containers/systemd/`, `systemctl daemon-reload && systemctl enable --now llama-server` |

> The quadlet units are **not installed by default** on this machine; the
> container currently running was started via the compose method.

## Tagging & deployment (Makefile)

The image tag is **computed, never hand-typed**. `TAGS` (repo root) is the
single source of truth for the build inputs; the Makefile derives:

    IMAGE_TAG = <LLAMA_BUILD>-rocm-<ROCM_VERSION>    e.g. b10896-rocm-7.2.4
    IMAGE     = localhost/llama-server:b10896-rocm-7.2.4    (+ a `latest` alias)

`make sync` rewrites the image reference — and the quadlet `BuildArg=` lines
plus the `LLAMA_ARG_HF_REPO` model ref — in all three deployment methods, so
the three equivalent files above can never drift on the image reference;
`make verify` fails on drift.

| Command | Effect |
|---|---|
| `make show` | active tag + every image reference in the repo |
| `make verify` | fail unless every deploy file references exactly the active tag |
| `make new-build BUILD=b12345 COMMIT=<sha>` | point `TAGS` at a new llama.cpp build (optional `ROCM=`, `FEDORA=`, `GPU_TARGET=`) |
| `make build` | `podman build` with `BRANCH=<LLAMA_COMMIT>` pinned; tags `IMAGE` + `latest` |
| `make tag FROM=<old-tag>` | retag an existing local image to the active tag (no rebuild) |
| `make sync` | rewrite image refs / build args / model ref in all three methods |
| `make deploy [METHOD=compose\|script\|quadlet]` | `sync`, then start via the chosen method (default `compose`) |
| `make down` / `stop` / `logs` / `status` | container lifecycle; `status` also runs `verify` |

Deploying a new tag:

    make new-build BUILD=b12345 COMMIT=<sha>    # 1. point TAGS at the build
    make build                                  # 2. build it — or `make tag FROM=<old-tag>` to reuse an existing image
    make deploy                                 # 3. recreate the container on the new tag

- `LLAMA_BUILD` / `LLAMA_COMMIT` are read from the image's
  `llama-server --version` output (`build 10896, commit fa6769818...`), so
  the tag always describes the exact binary inside.
- The Containerfile's default `BRANCH` and the quadlet `BuildArg=BRANCH=`
  are pinned to the same commit; `make sync` keeps the quadlet lines
  current.
- `make deploy-quadlet` needs root: it installs the units into
  `/etc/containers/systemd/llama-server/`, then starts
  `llama-server-build.service` and `llama-server.service`.

## 1. The fix: IPC namespace (mandatory)

The model cannot load in a container with the *default* (private) IPC
namespace, even with `shm_size` bumped to 64GB:

```
model buffer is using system RAM (no shared memory detected) ...
LLAMA_FAILED_TO_ALLOCATE / memory in use
```

Only `--ipc=host` (the host's ~63GB /dev/shm namespace) works. This is why
`llama-server.sh` works and the compose stack originally failed.

- `podman-compose.yml` → `ipc: host`
- **`podman-compose` v1.6.0 has a bug: it parses `ipc:` but never emits
  `--ipc` to the `podman run` argv.** The local install is patched
  (2 lines after the `shm_size` handler). `scripts/fedora-setup.sh` §3.7
  re-applies the patch idempotently and verifies the running container
  reports `IpcMode=host`.

> **Re-run `scripts/fedora-setup.sh` after any podman-compose
> reinstall/update** — the patch is lost otherwise, and this exact failure
> returns.

## 2. Tuning pass — results

Goal: find the parameters for maximum tokens/sec.
Baseline from `llama-server` logs: **10.17–10.80 t/s** (idle windows).

Eight parameter combinations were tested against the live baseline
(`tune.sh`, `tune_pass2.sh`, `validate.sh`, `lullhunt.sh`):

### Contended-window samples (baseline container busy — 6 samples each)

| Config | tps (6 samples) | mean |
|---|---|---|
| **compose_cur** (q8_0 KV, ctx 262144, np1, T8, flash on, mmap off) | 5.37, 5.37, 5.33, 5.53, 5.35, 5.42 | **5.40** |
| f16kv (ctx 262144, f16 cache) | 5.41, 5.41, 5.41, 5.41, 5.47, 5.55 | 5.44 |
| mmap_on (q8_0, ctx 262144, mmap on) | 5.47, 5.44, 5.43, 5.42, 5.43, 5.87 | 5.51 |

All configs cluster within ~2% when the GPU is shared — the baseline
container's workload is the binding constraint, not any of these knobs.

### Lull-window samples (baseline easing off — 8 samples each)

| Config | tps (8 samples) | peak |
|---|---|---|
| **compose_cur** | 7.63, 6.60, 10.94, 7.85, 10.42, 8.54, 8.47, 6.24 | **10.94** |
| mmap_on | 5.56, 5.42, 5.35, 5.56, 7.71, 8.83, 8.41, 8.36 | 8.83 |

Pass-1 fully-clean sample (no contention at all): **compose_cur = 11.72 t/s**,
above the baseline's 10.17–10.80 idle range.

### Best parameters (final `podman-compose.yml` state)

```yaml
environment:
  LLAMA_ARG_THREADS: "8"
  LLAMA_ARG_LOAD_MODE: "auto"
  LLAMA_ARG_CTX_SIZE: "262144"
  LLAMA_ARG_FLASH_ATTN: "on"
  LLAMA_ARG_N_PARALLEL: "1"
  LLAMA_ARG_SPEC_TYPE: "draft-mtp"
  LLAMA_ARG_CACHE_TYPE_K: "q8_0"
  LLAMA_ARG_CACHE_TYPE_V: "q8_0"
```

**No parameter change beat the compose stack's current configuration.**

- `ipc: host` is the only decisive parameter (without it, t/s = 0 — the
  model can't load).
- ctx 32K / 393K, n_parallel 2, f16 KV, mmap on, batch 128/64: no measured
  gain over the values above in either contended or lull windows.
- The explicit `q8_0` KV cache halves KV memory vs the default f16 and is
  the config that reached 11.72 t/s clean.
- **Env var audit (b10884, 2026-09-09):** `LLAMA_ARG_MMAP`,
  `LLAMA_ARG_TEMP`, `LLAMA_ARG_TOP_P`, and `LLAMA_ARG_MIN_P` do not exist in
  this build (verified against the binary), so the mmap on/off rows above both
  actually ran with the default `auto` (mmap on). The canonical set now pins
  the measured behavior with `LLAMA_ARG_LOAD_MODE=auto` and adds
  `LLAMA_ARG_SPEC_TYPE=draft-mtp`, enabling self-speculative decoding via the
  model's built-in MTP head (`qwen35.nextn_predict_layers=1`, tensors
  `blk.64.nextn.*`). Effective sampling comes from the model file
  (temp 1.0, top_p 0.95, top_k 20) plus the server default min_p 0.05.

## 3. Caveats

- **Shared GPU contention:** the tuning pass in §2 was run while an older
  baseline container shared the iGPU. While *any* other GPU workload is
  mid-generation, throughput drops to ~5–6 t/s. Absolute numbers from §2
  are only meaningful during quiet windows; relative ranking is stable.
- **podman-compose patch durability:** see §1 — re-run
  `scripts/fedora-setup.sh` after any package reinstall/update.
- **Deployment methods are aligned:** as of 2026-09-09 all three methods
  (script, compose, quadlet) carry the same runtime config and the same
  24 `LLAMA_ARG_*` env vars — the tuned values from §2 plus the Web UI /
  agent feature flags, the b10884 env var audit fix (`LOAD_MODE` replaces the
  dead `MMAP`; dead `TEMP`/`TOP_P`/`MIN_P` removed), and
  `SPEC_TYPE=draft-mtp` (MTP speculative decoding). The old
  script/quadlet variants (ctx 393216, n_parallel 2/4, no explicit KV
  cache type, `LLAMA_ARG_MODELS_DIR`) were
  superseded; `MODELS_DIR` is a no-op for current llama-server builds
  (`-hf` resolution uses the HF cache dir, not `--models-dir`).
- **Feature flags:** `LLAMA_ARG_AGENT=on` (which implies
  `LLAMA_ARG_TOOLS=all` and the MCP proxy) is experimental per llama.cpp —
  "do not enable in untrusted environments". The server also listens on
  `0.0.0.0:8000` without an API key; keep it on trusted networks only.
- **Live stack aligned:** the running container was recreated on 2026-09-09
  via `podman compose up -d` with the full aligned 24-var env (adds
  `UI`/`AGENT`/`TOOLS` on top of the previously tuned set, plus the b10884
  audit fix).
