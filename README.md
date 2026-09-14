# fedora-llamacpp

Podman-based deployment of `llama-server` (llama.cpp, ROCm 10 gfx1151) running
Qwen3.8-27B-GGUF (UD-Q4_K_XL) on Strix Halo (Ryzen AI Max+ 395, 32GB UMA).

ROCm 10 is installed **with pip wheels** (no repo.radeon.com RPMs) — see
"ROCm 10 via pip wheels" below.

The Makefile is the single interface for end users: it contains the full
container definition (name, image, env, devices, IPC, volumes, secret) and
needs at most three changes — `CONTAINER_NAME`, `IMAGE`, `PORT` — then:

    make deploy      # (re)create and start, wait for /health
    make status      # container state
    make logs        # follow the logs
    make stop / make down

Two equivalent **file-based** methods remain for operators; they define
the same container and are kept in lockstep with `TAGS` by `make sync`
(maintainer section of the Makefile). All three methods target the same
**production slot** — the container `llama-server` on :8000 — and run one
method at a time:

| Method | File(s) | Start |
|---|---|---|
| podman run (default) | `Makefile` | `make deploy` (replaces running container) |
| podman compose | `podman-compose.yml` | `make deploy-compose` (same `CONTAINER_NAME`/`IMAGE`/`PORT` overrides) |
| quadlet (systemd --user) | `config/containers/systemd/llama-server/*.container`, `*.build` | `make deploy-quadlet` (user namespace — no root needed) |

> The quadlet units are installed in the user namespace but **not
> enabled** on this machine; `make deploy` (plain `podman run`) is the
> default method.

> **Safety / production slot.** The deploy targets refuse to take over a
> slot owned by another method (an active quadlet unit, or a
> compose-managed container), so a stray `make deploy` — human or AI
> agent — cannot take production down; taking the slot is always a
> deliberate two-step act (e.g. `podman compose down && make deploy`).
> The quadlet config is **static** (pinned tag, never `:latest` — enforced
> by `make verify`), and the build/test flow (`make build`,
> `make deploy-test`, `make bench`, `make sync`) never touches the running
> production container. Promoting a new version is explicit:
> `make sync` (advance the pin) + the owning method's deploy target.

## The Makefile

The Makefile is the single interface. The **end-user** part at the top holds
the full container definition — at most three things need changing
(`CONTAINER_NAME`, `IMAGE`, `PORT`) — and the **maintainer** part at the
bottom builds and updates the image.

**End-user targets** (all you need to run the container):

| Command | Effect |
|---|---|
| `make deploy` | (re)create and start the container (`podman run --replace`), wait for `/health`; override with `CONTAINER_NAME=`, `IMAGE=`, `PORT=` |
| `make status` / `make logs` / `make stop` / `make down` | container lifecycle |

**Maintainer targets** (build & update the image). The image tag is
**computed, never hand-typed**. `TAGS` (repo root) is the single source of
truth for the build inputs; the Makefile derives:

    IMAGE_TAG = <LLAMA_BUILD>-rocm-<ROCM_VERSION>    e.g. b10902-rocm-10.0.0
    IMAGE     = localhost/llama-server:b10902-rocm-10.0.0    (+ a `latest` alias)

`make sync` rewrites the image reference — and the quadlet `BuildArg=` lines
plus the `LLAMA_ARG_HF_REPO` model ref — in all file-based deployment
methods, so the equivalent files can never drift on the image reference;
`make verify` fails on drift.

| Command | Effect |
|---|---|
| `make show` | active tag + every image reference in the repo |
| `make verify` | fail unless every file-based method references exactly the active tag |
| `make new-build BUILD=b12345 COMMIT=<sha>` | point `TAGS` at a new llama.cpp build (optional `ROCM=`, `FEDORA=`, `GPU_TARGET=`) |
| `make update` | zero-input update: discover the latest llama.cpp `b-tag` + newest ROCm with a `GPU_TARGET` wheel, update `TAGS`, build, sync, deploy, **label in git** (commit + tag) |
| `make update-dry` | preview `make update` (discover + diff + plan; nothing is changed) |
| `make build` | `podman build` with `BRANCH=<LLAMA_COMMIT>` pinned; tags `IMAGE` + `latest` |
| `make tag FROM=<old-tag>` | retag an existing local image to the active tag (no rebuild) |
| `make sync` | rewrite image refs / build args / model ref in all file-based methods |
| `make deploy-compose` / `make deploy-quadlet` | start via a file-based method instead of `make deploy` (compose honors the same three overrides); both refuse to take over the slot from another method |
| `make deploy-test` / `make down-test` / `make bench` | :8001 validation container (plain `podman run`, active TAGS image) + A/B throughput; never touches the production container (identity collisions are refused) |

Deploying a new tag:

    make new-build BUILD=b12345 COMMIT=<sha>    # 1. point TAGS at the build
    make build                                  # 2. build it — or `make tag FROM=<old-tag>` to reuse an existing image
    make deploy                                 # 3. recreate the container on the new tag

**Automatic update — `make update` takes no arguments.** It discovers the
latest llama.cpp (the newest `b<digits>` git tag on `ggml-org/llama.cpp`
via `git ls-remote`; the b-tag stream runs ahead of the `v`-releases) and
the newest ROCm that ships a linux wheel for `GPU_TARGET` on AMD's pip
index (`stable.repo.amd.com/rocm/whl-next/`) — newer ROCm releases are
skipped until they add a wheel for this GPU (only `10.0.0` has `gfx1151`).
If either is newer than `TAGS`, it rewrites `TAGS`, runs
`make build && make sync && make deploy`, waits for `/health`, then commits
`TAGS` + the synced deploy files and adds an **annotated git tag named
like the image tag** (e.g. `b10944-rocm-10.0.0`) — every deployed build
is labeled in git history. If a git remote is added, commit + tag are
pushed. Idempotent: exits 0 and does nothing when up to date (cron-safe).
`make update-dry` shows the discovery + diff without changing anything;
`scripts/update.py --no-deploy` builds + labels without touching the
running container.

- `LLAMA_BUILD` / `LLAMA_COMMIT` are read from the image's
  `llama-server --version` output (`build 10896, commit fa6769818...`), so
  the tag always describes the exact binary inside.
- The Containerfile's default `BRANCH` and the quadlet `BuildArg=BRANCH=`
  are pinned to the same commit; `make sync` keeps the quadlet lines
  current.
- `make deploy-quadlet` runs in the **user namespace** (no root): it
  installs the units into `~/.config/containers/systemd/llama-server/`,
  then starts `llama-server-build.service` and `llama-server.service` via
  `systemctl --user` (linger is enabled for this user, so the service
  survives logout).

## ROCm 10 via pip wheels

The image no longer uses the `repo.radeon.com` RPM repository. ROCm
`10.0.0` is installed from AMD's pip-wheel index, per AMD's pip install
docs (https://rocm.docs.amd.com, "Install ROCm wheel packages"), which for
this hardware (Ryzen AI Max / `gfx1151`) and Python 3.14 are:

```
python -m pip install --index-url https://stable.repo.amd.com/rocm/whl-next/ \
    "rocm[libraries,device-gfx1151]==10.0.0"
```

The Containerfile adds the `devel` extra on top (`rocm[libraries,devel,device-gfx1151]`)
because `llama.cpp` is compiled from source in the image: `devel` carries the
HIP compiler, CMake configs, headers and static libraries. The wheels unpack
a classic `/opt/rocm`-style tree under the venv:

| Wheel payload | Contents |
|---|---|
| `_rocm_sdk_core` | runtime libraries (HIP, HSA, comgr, SMI, ...) + `amdgpu.ids` |
| `_rocm_sdk_libraries` | rocBLAS / hipBLAS / hipBLASLt + `gfx1151` prebuilt kernels |
| `_rocm_sdk_devel` | SDK root: `hipcc`, clang/LLVM, CMake configs, headers, static libs |

Build stage (fedora:44): `dnf` installs only the host build tools
(`gcc g++ cmake ninja-build ...`, `python3` 3.14 + `python3-pip`); the venv
at `/opt/rocm-venv` holds the ROCm wheels; `rocm-sdk path --root` pins the
(de-lazily-expanded) SDK root, and `llama.cpp` is configured with the same
CMake flags as the old RPM build — `CMAKE_HIP_ARCHITECTURES=gfx1151`,
`GGML_HIP=1`, `GGML_RPC=1`, `LLAMA_HIP_UMA=1` — pointed at the wheel's SDK
root via `HIP_PATH`/`ROCM_PATH`/`HIP_CLANG_PATH`/`HIP_DEVICE_LIB_PATH`.
The wheel's `hipcc` compiles the HIP side; the host `gcc` compiles the
C/C++ side (same compiler split as the RPM build).

Runtime stage (fedora-minimal): only a **slim consolidated tree** is copied
to `/opt/rocm-10.0.0/lib` — the core runtime libs (HIP, HSA, comgr, SMI,
bundled sysdeps), the BLAS stack (rocBLAS / hipBLAS / hipBLASLt + their
`gfx1151` prebuilt kernels), and `amdgpu.ids` (also at
`/usr/share/libdrm/`). ROCm 10's rocBLAS additionally pulls its
`rocsolver` / `origami` / `rocroller` backends, which link against the
wheel's bundled LLVM/Clang runtime (`libLLVM.so.23.0git`,
`libclang-cpp.so.23.0git`) — those two runtime libs are included; the rest
of the LLVM toolchain (compiler, MLIR, clang tools) is not. No venv, no
compiler, no RPM repos. Final image: **1.41 GB** (vs 2.67 GB for the old
RPM-based `rocm-7.2.4` image). `LD_LIBRARY_PATH` points at
`/opt/rocm-10.0.0/lib`; `GGML_HIP_UMA=1` and `HIP_VISIBLE_DEVICES=0` stay
as before.

### ROCm 10.0.0 vs 7.2.4 — A/B (same llama.cpp b10902)

`scripts/bench.py` A/B: production server (`b10902-rocm-7.2.4`, :8000)
vs test container (`b10902-rocm-10.0.0`, :8001), identical llama.cpp
build (`build 10902`), Qwen3.8-27B Q4_K_XL with `draft-mtp` speculative
decoding, quiet iGPU, 3 runs × 128 tokens, alternating to equalize GPU
contention:

| | ROCm 7.2.4 | ROCm 10.0.0 |
|---|---|---|
| eval t/s (mean) | 28.30 | 25.31 |
| eval t/s (min) | 28.23 | 23.82 |
| prompt t/s (mean) | ~26.3 | ~21.2 |

**ROCm 10.0.0 is ≈10% slower on token generation** for this model on this
iGPU; prompt processing is comparable. The 10-wheel image is kept as the
maintainable single-pip-source build — flip production with
`make deploy` if/when the regression is acceptable or gone in a later ROCm.

## 1. The fix: IPC namespace (mandatory)

The model cannot load in a container with the *default* (private) IPC
namespace, even with `shm_size` bumped to 64GB:

```
model buffer is using system RAM (no shared memory detected) ...
LLAMA_FAILED_TO_ALLOCATE / memory in use
```

Only `--ipc=host` (the host's ~63GB /dev/shm namespace) works. This is why
a plain `podman run --ipc=host` works and the unpatched compose stack
originally failed.

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

## 3. Thinking mode (Qwen3.8)

Qwen3.8 is a **thinking** model. With the current configuration, thinking
is always on — including when tools are enabled — and assistant reasoning
traces are kept in conversation history. The server-level flags set in the
24 `LLAMA_ARG_*` env vars:

| Flag | Effect |
|---|---|
| `LLAMA_ARG_REASONING=on` | llama.cpp emits reasoning as a separate `reasoning` field in chat responses (reasoning is not disabled when tools are active) |
| `LLAMA_ARG_REASONING_EFFORT=medium` | passes a `reasoning_effort` hint to the chat template |

How the model's own chat template (arch `qwen35`, verified from the GGUF)
interprets it:

- **default effort is `xhigh`** — the template adds a "think carefully,
  thorough analysis" system-prompt push; `medium` drops that push (it
  injects no directive, so the model still thinks, just without the
  "be thorough" nudge). It is a prompt-level hint, **not a token budget**.
- `low` asks for concise thinking; `high`/`xhigh` add increasing
  "think carefully" directives; any other value is rejected with a
  template error.
- Thinking is **not** suppressed when tools are present (the template has
  no tools→no-thinking branch).

`reasoning_effort` is a server-level setting (this build has no
per-request field in its OpenAPI), so it is only changeable via the env
vars — all deploy files must stay in sync (`make sync` / `make verify`).

## 4. Caveats

- **Shared GPU contention:** the tuning pass in §2 was run while an older
  baseline container shared the iGPU. While *any* other GPU workload is
  mid-generation, throughput drops to ~5–6 t/s. Absolute numbers from §2
  are only meaningful during quiet windows; relative ranking is stable.
- **podman-compose patch durability:** see §1 — re-run
  `scripts/fedora-setup.sh` after any package reinstall/update.
- **Deployment methods are aligned:** the Makefile (default method) and all
  file-based methods (compose, quadlet) carry the same runtime
  config and the same 24 `LLAMA_ARG_*` env vars — the tuned values from §2
  plus the Web UI / agent feature flags, the thinking flags from §3, the
  b10884 env var audit fix (`LOAD_MODE` replaces the dead `MMAP`; dead
  `TEMP`/`TOP_P`/`MIN_P` removed), and `SPEC_TYPE=draft-mtp` (MTP
  speculative decoding). The old file-based
  variants (ctx 393216, n_parallel 2/4, no explicit KV
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
  audit fix); `REASONING_EFFORT=medium` was added on top for thinking mode
  (§3).
