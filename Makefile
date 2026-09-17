# ============================================================================
#  llamacpp-qwen3.8-27b — run a llama.cpp (ROCm, gfx1151) container on Podman
#
#  USERS
#  -----
#  The default deployment is the quadlet method (user systemd, no root). The
#  container definition lives in the quadlet units and compose.yaml.
#
#  The only end-user knob is the container name:
#      CONTAINER_NAME ?= qwen3.8-27b
#
#  A plain `podman compose` deployment (compose.yaml) is an operator
#  alternative. It is NOT a make target — see README.md, "podman compose
#  deployment", for the exact commands.
#
#  Everything else in this file is a tuned, fixed configuration for Strix
#  Halo (Ryzen AI Max+ 395, 32 GB UMA, gfx1151) — no need to touch it.
#
#  End-user targets:
#      make deploy     install quadlet units and start the service (user systemd)
#      make status     show container state
#      make logs       follow the container logs
#      make stop       stop the service
#
#  MAINTAINERS 
#  -----------
#  Change at the bottom builds and updates the image itself
#  (make build, make update) — not needed just to run the container.
# ============================================================================

SHELL := /bin/bash
MAKEFLAGS += --no-builtin-rules
.DEFAULT_GOAL := help

# ---------------------------------------------------------------------------
#  Container name (used by status/build/preflight; default qwen3.8-27b)
# ---------------------------------------------------------------------------

CONTAINER_NAME ?= qwen3.8-27b

# ---------------------------------------------------------------------------
#  Fixed configuration — model + tuned runtime (see README.md, sections 2-4)
#  The in-container port is always 8000; PORT is the port published on the
#  host.
# ---------------------------------------------------------------------------

.PHONY: help deploy status logs stop

help: ## Print this list. 
	@echo "container: $(CONTAINER_NAME)"
	@echo
	@grep -hE '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | \
		awk '{ n=index($$0, ":"); h=index($$0, "## "); \
		       printf "  make %-42s %s\n", substr($$0,1,n-1), substr($$0,h+3) }'

deploy: ## Deploy the container as a systemd service.
	@if podman ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$(CONTAINER_NAME)"; then \
		if ! systemctl --user is-active --quiet qwen3.8-27b.service 2>/dev/null; then \
			echo "REFUSED: a non-systemd container named '$(CONTAINER_NAME)' is present (compose or plain podman)"; \
			echo "         stop it first — podman compose down   — then re-run make deploy"; \
			exit 1; \
		fi; \
	fi
	podman quadlet install --application=qwen3.8-27b --reload-systemd --replace $(QUADLET_SRC)
	systemctl --user start qwen3.8-27b-build.service
	systemctl --user start qwen3.8-27b.service
	@# Warn if linger is not enabled (services only start at login, not at boot)
	if ! loginctl show-user "$$USER" -p Linger --value 2>/dev/null | grep -qx yes; then \
		echo; \
		echo "WARNING: linger is not enabled for '$$USER'."; \
		echo "         The services will start at login, but NOT at boot."; \
		echo "         To start them at boot (no login required):"; \
		echo "             sudo loginctl enable-linger $$USER"; \
		echo; \
	fi
status: ## Display status of current environment. 
	@echo "Build configuration:"
	@echo "  IMAGE_NAME : $(TAGGED_IMAGE)"
	@echo "  LLAMA_TAG      : $(LLAMA_TAG)"
	@echo "  ROCM_VERSION   : $(ROCM_VERSION)"
	@echo "  FEDORA_VERSION : $(FEDORA_VERSION)"
	@echo "  MODEL          : $(MODEL)"
	@echo
	@echo "Available images:"
	@podman image list --filter reference=qwen3.8-27b --format '  {{.Tag}} | {{.ID}} | {{.Created}}' | grep -v latest || true
	@echo
	@echo "Deployed container:"
	@podman ps -a --filter name=^/$(CONTAINER_NAME) --format '  {{.Names}} | {{.Image}} | {{.Status}}'

logs: ## Print systemd logs. 
	journalctl --user -fu qwen3.8-27b.service

stop: ## Stop the service
	systemctl --user stop qwen3.8-27b.service

# ============================================================================
#  MAINTAINER — build & update the image (not needed to run the container)
#
#  TAGS is the single source of truth for the image contents:
#
#      IMAGE_TAG = <LLAMA_TAG>-rocm-<ROCM_VERSION>     e.g. v0.4.1-rocm-10.0.0
#
#  Zero-input update (discovers the latest llama.cpp release tag (vX.Y.Z)
#  ROCm with a gfx1151 wheel, builds, syncs, deploys, and labels the
#  result in git — commit + annotated tag named like the image):
#
#      make update          # full cycle
#      make update-dry      # discover + diff + plan only
#
#  The file-based deploy methods (compose.yaml, quadlet) are kept in
#  lockstep with TAGS by `make sync`; `make verify` fails on drift.
# ============================================================================

TAGS := TAGS
LLAMA_REPO := https://github.com/ggml-org/llama.cpp.git
# Read KEY=VALUE from TAGS.
tagvar = $(strip $(shell awk -F= -v k="$(1)" '$$1==k{print $$2; exit}' $(TAGS) 2>/dev/null))

IMAGE_NAME     := $(call tagvar,IMAGE_NAME)
LLAMA_TAG      := $(call tagvar,LLAMA_TAG)
ROCM_VERSION   := $(call tagvar,ROCM_VERSION)
FEDORA_VERSION := $(call tagvar,FEDORA_VERSION)
MODEL          := $(call tagvar,MODEL)

IMAGE_TAG    := $(LLAMA_TAG)-rocm-$(ROCM_VERSION)
TAGGED_IMAGE := $(IMAGE_NAME):$(IMAGE_TAG)

CONTAINERFILE := Containerfile
QUADLET_SRC   := config/containers/systemd/qwen3.8-27b
DEPLOY_FILES  := compose.yaml \
                 $(QUADLET_SRC)/qwen3.8-27b.build \
                 $(QUADLET_SRC)/qwen3.8-27b.container

.PHONY: show verify sync build tag new-build update update-dry

sync: ## Rewrite image tag, build args and model ref; tag HEAD with the image tag.
	@echo "syncing deploy files -> $(TAGGED_IMAGE)"; \
	for f in $(DEPLOY_FILES); do \
		sed -i -E "s|$(IMAGE_NAME):[A-Za-z0-9._-]+|$(TAGGED_IMAGE)|g" $$f; \
	done; \
	sed -i -E \
		-e "s|^BuildArg=FEDORA_VERSION=.*|BuildArg=FEDORA_VERSION=$(FEDORA_VERSION)|" \
		-e "s|^BuildArg=ROCM_VERSION=.*|BuildArg=ROCM_VERSION=$(ROCM_VERSION)|" \
		-e "s|^BuildArg=BRANCH=.*|BuildArg=TAG=$(LLAMA_TAG)|" \
		-e "s|^BuildArg=TAG=.*|BuildArg=TAG=$(LLAMA_TAG)|" \
		$(QUADLET_SRC)/qwen3.8-27b.build; \
	old=$$(awk -F'"' '/LLAMA_ARG_HF_REPO/{print $$2; exit}' compose.yaml); \
	if [ -n "$$old" ] && [ "$$old" != "$(MODEL)" ]; then \
		echo "syncing model ref: $$old -> $(MODEL)"; \
		for f in $(DEPLOY_FILES); do \
			sed -i "s|$$old|$(MODEL)|g" $$f; \
		done; \
	else \
		echo "model ref already in sync"; \
	fi
	@if git rev-parse -q --verify "refs/tags/$(IMAGE_TAG)" >/dev/null 2>&1; then \
		echo "git tag $(IMAGE_TAG) already exists — leaving it untouched"; \
	else \
		git tag -a "$(IMAGE_TAG)" \
			-m "llama.cpp $(LLAMA_TAG) + ROCm $(ROCM_VERSION) — image $(TAGGED_IMAGE)"; \
		echo "tagged $$(git rev-parse --short HEAD) with $(IMAGE_TAG)"; \
	fi

build: ## Build the active TAGS image, pinned to the commit in TAGS.
	@running=$$(podman inspect "$(CONTAINER_NAME)" --format '{{.Image}}' 2>/dev/null); \
	tagid=$$(podman image inspect "$(TAGGED_IMAGE)" --format '{{.Id}}' 2>/dev/null); \
	if [ -n "$$running" ] && [ -n "$$tagid" ] && [ "$$running" = "$$tagid" ]; then \
		echo "WARNING: $(TAGGED_IMAGE) is what the running '$(CONTAINER_NAME)' container uses —"; \
		echo "         the rebuild replaces it in place (production keeps its current"; \
		echo "         binary until its next restart)."; \
	fi
	podman build -f $(CONTAINERFILE) \
		--build-arg FEDORA_VERSION=$(FEDORA_VERSION) \
		--build-arg ROCM_VERSION=$(ROCM_VERSION) \
		--build-arg TAG=$(LLAMA_TAG) \
		-t $(TAGGED_IMAGE) \
		.

parametric-build: ## Build the image for a specific parameters: LLAMA_TAG=<tag> ROCM=<version> FEDORA=<version>.
	@test -n "$(TAG)" || { echo "usage: make new-build TAG=<v-or-b-tag> [ROCM=x.y.z] [FEDORA=n]"; exit 2; }
	@{ c=$$(git ls-remote $(LLAMA_REPO) "refs/tags/$(TAG)^{}" 2>/dev/null | awk '{print $$1}' | head -1); \
	  [ -n "$$c" ] || c=$$(git ls-remote $(LLAMA_REPO) "refs/tags/$(TAG)" 2>/dev/null | awk '{print $$1}' | head -1); \
	  if [ -z "$$c" ]; then echo "ERROR: tag '$(TAG)' not found on $(LLAMA_REPO)"; exit 2; fi; \
	  sed -i "s|^LLAMA_TAG=.*|LLAMA_TAG=$(TAG)|" $(TAGS); \
	  { test -z "$(ROCM)" || sed -i "s|^ROCM_VERSION=.*|ROCM_VERSION=$(ROCM)|" $(TAGS); }; \
	  { test -z "$(FEDORA)" || sed -i "s|^FEDORA_VERSION=.*|FEDORA_VERSION=$(FEDORA)|" $(TAGS); }; \
	  echo "TAGS updated -> $(IMAGE_NAME):$(TAG)-rocm-$$(awk -F= -v k=ROCM_VERSION '$$1==k{print $$2}' $(TAGS))"; \
	  echo "next: make build && make deploy"; }
