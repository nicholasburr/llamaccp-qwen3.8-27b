#!/bin/bash
# Raw `podman run` deployment of llama-server (ROCm, Strix Halo).
#
# One of three EQUIVALENT deployment methods — all define the identical
# container (name, image, port 8000, devices, IPC, volumes, env); see
# README.md. Run exactly ONE of them at a time:
#   1. this script                     -> podman run
#   2. podman-compose.yml              -> podman compose up -d
#   3. config/containers/systemd/...   -> quadlet (llama-server.service)
#
# Prereqs: image localhost/llama-server:b10902-rocm-7.2.4 (see
# containers/Containerfile.llama-server), podman network "llama-network",
# podman secret "huggingface-token".
#
#   ./llama-server.sh          # start, or replace the running container
#   podman stop llama-server   # stop
set -euo pipefail

podman run --replace -itd --name llama-server \
  --network=llama-network \
  --device=/dev/dri \
  --device=/dev/kfd \
  --env=LLAMA_ARG_HF_REPO=unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_XL \
  --env=LLAMA_ARG_ALIAS=Qwen3.8-27B-ThinkingCoder \
  --env=LLAMA_ARG_LOG_TIMESTAMPS=on \
  --env=LLAMA_ARG_HOST=0.0.0.0 \
  --env=LLAMA_ARG_PORT=8000 \
  --env=LLAMA_ARG_THREADS=8 \
  --env=LLAMA_ARG_LOAD_MODE=auto \
  --env=LLAMA_ARG_FIT=off \
  --env=LLAMA_ARG_N_GPU_LAYERS=99 \
  --env=LLAMA_ARG_CTX_SIZE=262144 \
  --env=LLAMA_ARG_FLASH_ATTN=on \
  --env=LLAMA_ARG_N_PARALLEL=1 \
  --env=LLAMA_ARG_CONT_BATCHING=on \
  --env=LLAMA_ARG_SPEC_TYPE=draft-mtp \
  --env=LLAMA_ARG_CACHE_TYPE_K=q8_0 \
  --env=LLAMA_ARG_CACHE_TYPE_V=q8_0 \
  --env=LLAMA_ARG_UI=on \
  --env=LLAMA_ARG_UI_MCP_PROXY=on \
  --env=LLAMA_ARG_AGENT=on \
  --env=LLAMA_ARG_TOOLS=all \
  --env=LLAMA_ARG_REASONING=on \
  --env=LLAMA_ARG_THINK=auto \
  --env=LLAMA_ARG_JINJA=on \
  --env=LLAMA_ARG_TOP_K=20 \
  --group-add=video \
  --group-add=render \
  --ipc=host \
  --publish=8000:8000 \
  --restart=unless-stopped \
  --security-opt=seccomp=unconfined \
  --secret=huggingface-token,type=env,target=HF_TOKEN \
  --volume=/home/nburr/.cache/huggingface/hub/:/root/.cache/huggingface/hub/:Z \
  --volume=/home/nburr/.config/llama.cpp/:/root/.config/llama.cpp/:Z \
  localhost/llama-server:b10902-rocm-7.2.4
