#!/usr/bin/env python3
"""
update.py — build & deploy the latest llama.cpp + ROCm, labeled in git.

Zero input required. Each run:

  1. discovers the latest upstream versions:
       llama.cpp : newest `b<digits>` git tag on ggml-org/llama.cpp
                   (via `git ls-remote` — the b-tag stream is ahead of the
                   v-releases, and it matches the repo's existing pin scheme)
       ROCm      : newest version with a linux wheel for the GPU_TARGET
                   device package on AMD's pip index (whl-next) — newer
                   ROCm releases are skipped until they ship a wheel for
                   this GPU (e.g. gfx1151)
  2. diffs them against TAGS; if both are current, exits 0 (idempotent —
     safe to run from cron)
  3. otherwise:
       a. rewrites TAGS (LLAMA_BUILD, LLAMA_COMMIT, ROCM_VERSION)
       b. make build      ->  image <LLAMA_BUILD>-rocm-<ROCM_VERSION> (+ latest)
       c. make deploy     ->  recreates the production container (METHOD=compose)
       d. waits for http://127.0.0.1:8000/health
       e. git: commits TAGS + the synced deploy files and adds an annotated
          tag named exactly like the image tag (e.g. b10944-rocm-10.0.0),
          matching the existing tag scheme. Pushes commit + tag if a git
          remote is configured (there is none yet — labels stay local).

Usage:
  python3 scripts/update.py            # full cycle (also: make update)
  python3 scripts/update.py --dry-run  # discover + diff + plan only (make update-dry)
  python3 scripts/update.py --no-deploy  # build + label, leave the running
                                         # container alone (swap later: make deploy)
"""

import argparse
import json
import re
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TAGS = ROOT / "TAGS"

LLAMA_REPO = "https://github.com/ggml-org/llama.cpp"
ROCM_INDEX = "https://stable.repo.amd.com/rocm/whl-next/"
HEALTH_URL = "http://127.0.0.1:8000/health"

# deploy files rewritten by `make sync` (must mirror DEPLOY_FILES in the Makefile)
DEPLOY_FILES = [
    "scripts/llama-server.sh",
    "podman-compose.yml",
    "podman-compose.test.yml",
    "config/containers/systemd/llama-server/llama-server.build",
    "config/containers/systemd/llama-server/llama-server.container",
]


class UpdateError(RuntimeError):
    pass


def log(msg: str) -> None:
    print(f"[update] {msg}", flush=True)


def read_tags() -> dict:
    vals = {}
    for line in TAGS.read_text().splitlines():
        m = re.match(r"^([A-Z_]+)=(.*)$", line)
        if m:
            vals[m.group(1)] = m.group(2).strip()
    for key in ("LLAMA_BUILD", "LLAMA_COMMIT", "ROCM_VERSION", "GPU_TARGET"):
        if not vals.get(key):
            raise UpdateError(f"TAGS is missing {key}")
    return vals


def write_tags(vals: dict) -> None:
    """Rewrite LLAMA_BUILD / LLAMA_COMMIT / ROCM_VERSION in place, keep the rest."""
    lines = TAGS.read_text().splitlines(keepends=True)
    for key in ("LLAMA_BUILD", "LLAMA_COMMIT", "ROCM_VERSION"):
        new = f"{key}={vals[key]}"
        hits = [i for i, l in enumerate(lines) if l.startswith(f"{key}=")]
        if len(hits) != 1:
            raise UpdateError(f"expected exactly one {key}= line in TAGS, found {len(hits)}")
        lines[hits[0]] = new + "\n"
    TAGS.write_text("".join(lines))


def latest_llama() -> tuple:
    """Newest b<digits> tag on ggml-org/llama.cpp -> (tag, full commit sha)."""
    log(f"querying {LLAMA_REPO} for newest b-tag ...")
    out = subprocess.run(
        ["git", "ls-remote", "--tags", LLAMA_REPO],
        capture_output=True, text=True, timeout=120,
    )
    if out.returncode != 0:
        raise UpdateError(f"git ls-remote failed: {out.stderr.strip()}")
    best = None
    for line in out.stdout.splitlines():
        m = re.match(r"^([0-9a-f]{40})\s+refs/tags/(b[0-9]+)$", line)
        if m and (best is None or int(m.group(2)[1:]) > int(best[0][1:])):
            best = (m.group(2), m.group(1))
    if best is None:
        raise UpdateError("no b<digits> tags found on ggml-org/llama.cpp")
    log(f"latest llama.cpp: {best[0]} ({best[1][:9]})")
    return best


def _version_key(v: str) -> tuple:
    return tuple(int(p) for p in v.split("."))


def latest_rocm(gpu: str) -> str:
    """Newest ROCm version with a linux wheel for rocm-sdk-device-<gpu>."""
    url = f"{ROCM_INDEX}rocm-sdk-device-{gpu}/"
    log(f"querying {url} for newest device wheel ...")
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "fedora-llamacpp-update"})
        html = urllib.request.urlopen(req, timeout=60).read().decode()
    except Exception as e:
        raise UpdateError(
            f"cannot fetch ROCm index for {gpu} ({e}) — "
            f"no rocm-sdk-device-{gpu} package means this GPU is not supported there"
        )
    versions = set()
    for m in re.finditer(
        rf'rocm_sdk_device_{re.escape(gpu)}-(\d+(?:\.\d+)*)(?:-[^"]*)?-py3-none-linux_x86_64\.whl',
        html,
    ):
        versions.add(m.group(1))
    if not versions:
        raise UpdateError(f"no linux wheels for rocm-sdk-device-{gpu} on the index")
    best = max(versions, key=_version_key)
    log(f"latest ROCm with a {gpu} wheel: {best}")
    return best
def git(*args: str) -> str:
    out = subprocess.run(["git", "-C", str(ROOT), *args],
                         capture_output=True, text=True)
    if out.returncode != 0:
        raise UpdateError(f"git {' '.join(args)} failed: {out.stderr.strip()}")
    return out.stdout.strip()


def make(target: str) -> None:
    log(f"make {target}")
    subprocess.run(["make", target], cwd=ROOT)


def wait_health(timeout_s: int = 420) -> None:
    deadline = time.time() + timeout_s
    log("waiting for production health ...")
    while time.time() < deadline:
        try:
            body = urllib.request.urlopen(HEALTH_URL, timeout=5).read().decode()
            if json.loads(body).get("status") == "ok":
                log("health ok")
                return
        except Exception:
            pass
        time.sleep(10)
    raise UpdateError(f"{HEALTH_URL} not ok within {timeout_s}s — check `make logs`")


def main() -> int:
    ap = argparse.ArgumentParser(description="build & deploy the latest llama.cpp + ROCm, labeled in git")
    ap.add_argument("--dry-run", action="store_true",
                    help="discover and diff only; no build/deploy/git")
    ap.add_argument("--no-deploy", action="store_true",
                    help="build and label, but do not recreate the production container")
    args = ap.parse_args()

    cur = read_tags()
    cur_tag = f"{cur['LLAMA_BUILD']}-rocm-{cur['ROCM_VERSION']}"

    try:
        new_build, new_commit = latest_llama()
        new_rocm = latest_rocm(cur["GPU_TARGET"])
    except UpdateError as e:
        log(f"ERROR: {e}")
        return 1

    new_tag = f"{new_build}-rocm-{new_rocm}"
    changed = ((new_build, new_commit) != (cur["LLAMA_BUILD"], cur["LLAMA_COMMIT"])) \
        or (new_rocm != cur["ROCM_VERSION"])

    print()
    print(f"  llama.cpp : {cur['LLAMA_BUILD']} ({cur['LLAMA_COMMIT'][:9]})"
          f"  ->  {new_build} ({new_commit[:9]})"
          + ("   [updated]" if (new_build, new_commit) != (cur["LLAMA_BUILD"], cur["LLAMA_COMMIT"]) else ""))
    print(f"  ROCm      : {cur['ROCM_VERSION']}  ->  {new_rocm}"
          + ("   [updated]" if new_rocm != cur["ROCM_VERSION"] else ""))
    print(f"  image tag : {cur_tag}  ->  {new_tag}")
    print()

    if not changed:
        log("up to date — nothing to do")
        return 0
    if args.dry_run:
        log("dry run — would: rewrite TAGS, make build, "
            + ("make deploy, wait for health, " if not args.no_deploy else "")
            + f"git commit + tag {new_tag}")
        return 0

    # 1. TAGS -> build -> deploy -> health
    new_vals = dict(cur, LLAMA_BUILD=new_build, LLAMA_COMMIT=new_commit, ROCM_VERSION=new_rocm)
    write_tags(new_vals)
    log(f"TAGS updated -> {new_tag}")
    try:
        make("build")
        if not args.no_deploy:
            make("deploy")
            wait_health()
        else:
            log("--no-deploy: container untouched; run `make deploy` to swap")
    except UpdateError as e:
        log(f"ERROR: {e}")
        log("TAGS was rewritten — revert with: git checkout -- TAGS && make sync")
        return 1
    except subprocess.CalledProcessError:
        log("ERROR: build/deploy failed (see output above)")
        log("TAGS was rewritten — revert with: git checkout -- TAGS && make sync")
        return 1

    # 2. git label: commit TAGS + synced deploy files, tag like the image
    try:
        if git("rev-parse", "-q", "--verify", f"refs/tags/{new_tag}"):
            raise UpdateError(f"git tag {new_tag} already exists — refusing to move it")
        git("add", "--", "TAGS", *DEPLOY_FILES)
        if not git("diff", "--cached", "--name-only"):
            raise UpdateError("nothing staged — unexpected; aborting before commit")
        subject = (f"Update to llama.cpp {new_build} ({new_commit[:9]})"
                   f" + ROCm {new_rocm}; image {new_tag} built and deployed")
        if args.no_deploy:
            subject = subject.replace("built and deployed", "built (not yet deployed)")
        body = (
            "Automated by scripts/update.py (make update).\n"
            f"- llama.cpp: {cur['LLAMA_BUILD']} ({cur['LLAMA_COMMIT'][:9]}) -> {new_build} ({new_commit[:9]})\n"
            f"- ROCm:      {cur['ROCM_VERSION']} -> {new_rocm}\n"
            f"- image:     localhost/llama-server:{new_tag} (+ :latest)\n"
            + (f"- deployed:  llama-server on :8000, /health ok\n" if not args.no_deploy
               else "- deployed:  not run (--no-deploy); `make deploy` to swap\n"))
        git("commit", "-m", subject, "-m", body)
        git("tag", "-a", new_tag, "-m",
            f"llama.cpp {new_build} + ROCm {new_rocm} — image localhost/llama-server:{new_tag}")
        remotes = [r for r in git("remote").splitlines() if r.strip()]
        for r in remotes:
            git("push", r, "HEAD", new_tag)
            log(f"pushed commit + tag to {r}")
    except UpdateError as e:
        log(f"ERROR: {e}")
        log(f"image is built" + ("" if args.no_deploy else " and deployed")
            + f"; label it manually: git add TAGS <deploy files> && git commit && git tag -a {new_tag}")
        return 1

    print()
    if not args.no_deploy:
        log(f"done — production is now {new_tag}")
    else:
        log(f"done — image {new_tag} built (run `make deploy` to swap)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

