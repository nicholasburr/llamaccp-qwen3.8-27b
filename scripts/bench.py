#!/usr/bin/env python3
"""A/B throughput benchmark for two llama-server instances.

Sends an identical chat prompt (stream=false, temperature=0) alternately to
the production server (default port 8000) and the test server (default port
8001), and reports tokens/sec from each server's own `timings` response
field. Alternation keeps GPU contention symmetric between the two.

Usage:
    python3 scripts/bench.py [--runs 3] [--max-tokens 128]
                             [--base-port 8000] [--test-port 8001]
                             [--prompt "..."]

Requires both servers to be running and healthy. Uses only the stdlib.
"""

import argparse
import json
import statistics
import sys
import time
import urllib.error
import urllib.request

PROMPT_DEFAULT = "Write a haiku about the sea."


def one_request(port: int, prompt: str, max_tokens: int, timeout: float) -> dict:
    body = json.dumps(
        {
            "model": "local-model",
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": max_tokens,
            "temperature": 0,
            "stream": False,
        }
    ).encode()
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/v1/chat/completions",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.loads(resp.read())
    wall = time.time() - t0

    timings = data.get("timings", {})
    # llama.cpp renamed predict_n/predict_ms -> predicted_n/predicted_ms;
    # accept both so the script works against old and new servers.
    pred_n = timings.get("predicted_n", timings.get("predict_n", 0))
    pred_ms = timings.get("predicted_ms", timings.get("predict_ms", 0.0))
    prompt_n = timings.get("prompt_n", 0)
    prompt_ms = timings.get("prompt_ms", 0.0)
    return {
        "wall_s": wall,
        "pred_n": pred_n,
        "pred_tps": (pred_n / (pred_ms / 1000.0)) if pred_ms > 0 else 0.0,
        "prompt_tps": (prompt_n / (prompt_ms / 1000.0)) if prompt_ms > 0 else 0.0,
    }


def run_one(name: str, port: int, prompt: str, max_tokens: int) -> dict:
    r = one_request(port, prompt, max_tokens, 900)
    print(
        f"  {name:10s}: "
        f"{r['pred_tps']:6.2f} t/s eval ({r['pred_n']} tok), "
        f"{r['prompt_tps']:6.2f} t/s prompt, wall {r['wall_s']:.1f}s"
    )
    return r


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--max-tokens", type=int, default=128)
    ap.add_argument("--base-port", type=int, default=8000)
    ap.add_argument("--test-port", type=int, default=8001)
    ap.add_argument("--prompt", default=PROMPT_DEFAULT)
    args = ap.parse_args()

    print(f"prompt: {args.prompt!r}  (max_tokens={args.max_tokens}, runs={args.runs}, temp=0)")
    print("NOTE: both servers share the iGPU — alternating runs to keep contention symmetric.\n")

    # Warmup (discarded) on both: JIT/kernel paths + flash-attn planning settle.
    for name, port in (("base", args.base_port), ("test", args.test_port)):
        try:
            one_request(port, args.prompt, max(16, args.max_tokens // 8), timeout=600)
        except (urllib.error.URLError, TimeoutError) as e:
            sys.exit(f"error: {name} (port {port}) warmup failed: {e}")

    base, test = [], []
    for i in range(1, args.runs + 1):
        print(f"--- iteration {i}/{args.runs} ---")
        try:
            base.append(run_one("base", args.base_port, args.prompt, args.max_tokens))
            test.append(run_one("test", args.test_port, args.prompt, args.max_tokens))
        except (urllib.error.URLError, TimeoutError) as e:
            sys.exit(f"error: iteration {i} failed: {e}")

    base_tps = [r["pred_tps"] for r in base]
    test_tps = [r["pred_tps"] for r in test]
    print()
    print(f"{'':12s} {'base (8000)':>14s} {'test (8001)':>14s}")
    print(f"{'eval t/s':12s} {statistics.mean(base_tps):14.2f} {statistics.mean(test_tps):14.2f}   (mean)")
    print(f"{'eval t/s':12s} {min(base_tps):14.2f} {min(test_tps):14.2f}   (min)")
    if statistics.mean(base_tps) > 0:
        delta = (statistics.mean(test_tps) / statistics.mean(base_tps) - 1) * 100
        print(f"\nmean test vs base: {delta:+.1f}%")


if __name__ == "__main__":
    main()