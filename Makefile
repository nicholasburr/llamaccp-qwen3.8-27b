# ============================================================================
#  fedora-llamacpp — run a llama.cpp (ROCm, gfx1151) container on Podman
#
#  USERS
#  -----
#  The default deployment is the quadlet method (user systemd, no root). The
#  container definition lives in the quadlet units and podman-compose.yml.
#
#  The only end-user knob is the container name:
#      CONTAINER_NAME ?= llama-server
#
#  A plain `podman compose` deployment (podman-compose.yml) is an operator
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
#  Container name (used by status/build/preflight; default llama-server)
# ---------------------------------------------------------------------------

CONTAINER_NAME ?= llama-server

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
		if ! systemctl --user is-active --quiet llama-server.service 2>/dev/null; then \
			echo "REFUSED: a non-systemd container named '$(CONTAINER_NAME)' is present (compose or plain podman)"; \
			echo "         stop it first — podman compose down   — then re-run make deploy"; \
			exit 1; \
		fi; \
	fi
	podman quadlet install --application=llama-server --replace $(QUADLET_SRC) --daemon-reload/
	systemctl --user start llama-server-build.service
	systemctl --user start llama-server.service
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
	@echo "  LLAMA_BUILD    : $(LLAMA_BUILD)  (commit $(LLAMA_COMMIT))"
	@echo "  ROCM_VERSION   : $(ROCM_VERSION)"
	@echo "  FEDORA_VERSION : $(FEDORA_VERSION)"
	@echo "  MODEL          : $(MODEL)"
	@echo
	@echo "Available images:"
	@podman image list --filter reference=llama-server --format '  {{.Tag}} | {{.ID}} | {{.Created}}' | grep -v latest 
	@echo
	@echo "Deployed container:"
	@podman ps -a --filter name=^/$(CONTAINER_NAME) --format '  {{.Names}} | {{.Image}} | {{.Status}}'

logs: ## Print systemd logs. 
	journalctl --user -fu llama-server.service

stop: ## Stop the service
	systemctl --user stop llama-server.service

# ============================================================================
#  MAINTAINER — build & update the image (not needed to run the container)
#
#  TAGS is the single source of truth for the image contents:
#
#      IMAGE_TAG = <LLAMA_BUILD>-rocm-<ROCM_VERSION>     e.g. v0.4.1-rocm-10.0.0
#
#  Zero-input update (discovers the latest llama.cpp release tag (vX.Y.Z)
#  ROCm with a gfx1151 wheel, builds, syncs, deploys, and labels the
#  result in git — commit + annotated tag named like the image):
#
#      make update          # full cycle
#      make update-dry      # discover + diff + plan only
#
#  The file-based deploy methods (podman-compose.yml, quadlet) are kept in
#  lockstep with TAGS by `make sync`; `make verify` fails on drift.
# ============================================================================

TAGS := TAGS
LLAMA_REPO := https://github.com/ggml-org/llama.cpp.git
# Read KEY=VALUE from TAGS.
tagvar = $(strip $(shell awk -F= -v k="$(1)" '$$1==k{print $$2; exit}' $(TAGS) 2>/dev/null))

IMAGE_NAME     := $(call tagvar,IMAGE_NAME)
LLAMA_BUILD    := $(call tagvar,LLAMA_BUILD)
LLAMA_COMMIT   := $(call tagvar,LLAMA_COMMIT)
ROCM_VERSION   := $(call tagvar,ROCM_VERSION)
FEDORA_VERSION := $(call tagvar,FEDORA_VERSION)
MODEL          := $(call tagvar,MODEL)

IMAGE_TAG    := $(LLAMA_BUILD)-rocm-$(ROCM_VERSION)
TAGGED_IMAGE := $(IMAGE_NAME):$(IMAGE_TAG)

CONTAINERFILE := containers/Containerfile.llama-server
QUADLET_SRC   := config/containers/systemd/llama-server
DEPLOY_FILES  := podman-compose.yml \
                 $(QUADLET_SRC)/llama-server.build \
                 $(QUADLET_SRC)/llama-server.container

.PHONY: show verify sync build tag new-build update update-dry

sync: ## [maintainer] rewrite image tag, build args and model ref in all file-based methods to match TAGS
	@echo "syncing deploy files -> $(TAGGED_IMAGE)"; \
	for f in $(DEPLOY_FILES); do \
		sed -i -E "s|$(IMAGE_NAME):[A-Za-z0-9._-]+|$(TAGGED_IMAGE)|g" $$f; \
	done; \
	sed -i -E \
		-e "s|^BuildArg=FEDORA_VERSION=.*|BuildArg=FEDORA_VERSION=$(FEDORA_VERSION)|" \
		-e "s|^BuildArg=ROCM_VERSION=.*|BuildArg=ROCM_VERSION=$(ROCM_VERSION)|" \
		-e "s|^BuildArg=BRANCH=.*|BuildArg=TAG=$(LLAMA_BUILD)|" \
		-e "s|^BuildArg=TAG=.*|BuildArg=TAG=$(LLAMA_BUILD)|" \
		$(QUADLET_SRC)/llama-server.build; \
	old=$$(awk -F'"' '/LLAMA_ARG_HF_REPO/{print $$2; exit}' podman-compose.yml); \
	if [ -n "$$old" ] && [ "$$old" != "$(MODEL)" ]; then \
		echo "syncing model ref: $$old -> $(MODEL)"; \
		for f in $(DEPLOY_FILES); do \
			sed -i "s|$$old|$(MODEL)|g" $$f; \
		done; \
	else \
		echo "model ref already in sync"; \
	fi
	@$(MAKE) --no-print-directory verify

build: ## [maintainer] build the active TAGS image (+ :latest), pinned to the commit in TAGS
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
		--build-arg TAG=$(LLAMA_BUILD) \
		-t $(TAGGED_IMAGE) \
		.

parametric-build: ## [maintainer] point TAGS at a llama.cpp tag (release vX.Y.Z or nightly bXXXXX): make new-build TAG=v0.4.1 [ROCM=x.y.z] [FEDORA=n]
	@test -n "$(TAG)" || { echo "usage: make new-build TAG=<v-or-b-tag> [ROCM=x.y.z] [FEDORA=n]"; exit 2; }
	@{ c=$$(git ls-remote $(LLAMA_REPO) "refs/tags/$(TAG)^{}" 2>/dev/null | awk '{print $$1}' | head -1); \
	  [ -n "$$c" ] || c=$$(git ls-remote $(LLAMA_REPO) "refs/tags/$(TAG)" 2>/dev/null | awk '{print $$1}' | head -1); \
	  if [ -z "$$c" ]; then echo "ERROR: tag '$(TAG)' not found on $(LLAMA_REPO)"; exit 2; fi; \
	  sed -i "s|^LLAMA_BUILD=.*|LLAMA_BUILD=$(TAG)|" $(TAGS); \
	  sed -i "s|^LLAMA_COMMIT=.*|LLAMA_COMMIT=$$c|" $(TAGS); \
	  { test -z "$(ROCM)" || sed -i "s|^ROCM_VERSION=.*|ROCM_VERSION=$(ROCM)|" $(TAGS); }; \
	  { test -z "$(FEDORA)" || sed -i "s|^FEDORA_VERSION=.*|FEDORA_VERSION=$(FEDORA)|" $(TAGS); }; \
	  echo "TAGS updated -> $(IMAGE_NAME):$(TAG)-rocm-$$(awk -F= -v k=ROCM_VERSION '$$1==k{print $$2}' $(TAGS))  (commit $$c)"; \
	  echo "next: make build && make deploy"; }

update: ## [maintainer] zero input: latest llama.cpp + ROCm; build, sync, deploy, label in git (commit + tag)
	python3 scripts/update.py

update-dry: ## [maintainer] preview make update (discover latest versions + diff + plan; nothing is changed)
	python3 scripts/update.py --dry-run
