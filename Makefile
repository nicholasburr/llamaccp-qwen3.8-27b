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

help: ## show the available targets
	@echo "container: $(CONTAINER_NAME)"
	@echo
	@grep -hE '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | \
		awk '{ n=index($$0, ":"); h=index($$0, "## "); \
		       printf "  make %-42s %s\n", substr($$0,1,n-1), substr($$0,h+3) }'

deploy: ## install quadlet units and start the service (user systemd — no root needed)
	@if podman ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$(CONTAINER_NAME)"; then \
		if ! systemctl --user is-active --quiet llama-server.service 2>/dev/null; then \
			echo "REFUSED: a non-systemd container named '$(CONTAINER_NAME)' is present (compose or plain podman)"; \
			echo "         stop it first — podman compose down   — then re-run make deploy"; \
			exit 1; \
		fi; \
	fi
	podman quadlet install --application=llama-server --replace $(QUADLET_SRC)/
	systemctl --user daemon-reload
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

status: ## show container state
	podman ps -a --filter name=^/$(CONTAINER_NAME) --format '  {{.Names}} | {{.Image}} | {{.Status}}'

logs: ## follow the container logs
	journalctl --user -fu llama-server.service

stop: ## stop the service
	systemctl --user stop llama-server.service

# ============================================================================
#  MAINTAINER — build & update the image (not needed to run the container)
#
#  TAGS is the single source of truth for the image contents:
#
#      IMAGE_TAG = <LLAMA_BUILD>-rocm-<ROCM_VERSION>     e.g. b10902-rocm-10.0.0
#
#  Zero-input update (discovers the latest llama.cpp b-tag and the newest
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

show: ## [maintainer] show the active image and every image reference in the repo
	@echo "IMAGE_NAME : $(TAGGED_IMAGE)"
	@echo "LLAMA_BUILD    : $(LLAMA_BUILD)  (commit $(LLAMA_COMMIT))"
	@echo "ROCM_VERSION   : $(ROCM_VERSION)"
	@echo "FEDORA_VERSION : $(FEDORA_VERSION)"
	@echo "MODEL          : $(MODEL)"
	@echo
	@echo "image references in deploy files:"
	@grep -HnoE '$(IMAGE_NAME):[A-Za-z0-9._-]+' $(DEPLOY_FILES) | sed 's/^/  /'
	@echo
	@if grep -qE '^Image=.*:latest' $(QUADLET_SRC)/llama-server.container; then \
		echo "ERROR: quadlet config must pin a build tag (Image=localhost/llama-server:b...-rocm-...), never :latest"; \
		exit 1; \
	fi
	@refs=$$(grep -hoE '$(IMAGE_NAME):[A-Za-z0-9._-]+' $(DEPLOY_FILES) | sort -u); \
	n=$$(printf '%s\n' "$$refs" | grep -c . || true); \
	echo "Deploy files reference $$n distinct tag(s):"; \
	printf '%s\n' "$$refs" | sed 's/^/  /'; \
	if [ "$$n" -eq 1 ] && [ "$$refs" = "$(TAGGED_IMAGE)" ]; then \
		echo "OK — all methods in sync with $(TAGGED_IMAGE)"; \
	else \
		echo "DRIFT — expected only $(TAGGED_IMAGE); fix with: make sync"; exit 1; \
	fi

sync: ## [maintainer] rewrite image tag, build args and model ref in all file-based methods to match TAGS
	@echo "syncing deploy files -> $(TAGGED_IMAGE)"; \
	for f in $(DEPLOY_FILES); do \
		sed -i -E "s|$(IMAGE_NAME):[A-Za-z0-9._-]+|$(TAGGED_IMAGE)|g" $$f; \
	done; \
	sed -i -E \
		-e "s|^BuildArg=FEDORA_VERSION=.*|BuildArg=FEDORA_VERSION=$(FEDORA_VERSION)|" \
		-e "s|^BuildArg=ROCM_VERSION=.*|BuildArg=ROCM_VERSION=$(ROCM_VERSION)|" \
		-e "s|^BuildArg=BRANCH=.*|BuildArg=BRANCH=$(LLAMA_COMMIT)|" \
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
		--build-arg BRANCH=$(LLAMA_COMMIT) \
		-t $(TAGGED_IMAGE) \
		-t $(IMAGE_NAME):latest \
		.

tag: ## [maintainer] retag an existing local image as the active TAGS image (no rebuild): make tag FROM=rocm-10.0.0
	@test -n "$(FROM)" || { echo "usage: make tag FROM=<current-tag>   (e.g. FROM=rocm-10.0.0)"; exit 2; }
	podman tag $(IMAGE_NAME):$(FROM) $(TAGGED_IMAGE)
	podman tag $(IMAGE_NAME):$(FROM) $(IMAGE_NAME):latest
	@podman images --format '{{.Repository}}:{{.Tag}}  ({{.Size}})' | grep -F "$(IMAGE_NAME):" | sed 's/^/  /'

new-build: ## [maintainer] point TAGS at a new llama.cpp build: make new-build BUILD=b12345 COMMIT=<sha> [ROCM=x.y.z] [FEDORA=n]
	@test -n "$(BUILD)" && test -n "$(COMMIT)" || { echo "usage: make new-build BUILD=b12345 COMMIT=<sha> [ROCM=x.y.z] [FEDORA=n]"; exit 2; }
	@sed -i "s|^LLAMA_BUILD=.*|LLAMA_BUILD=$(BUILD)|" $(TAGS)
	@sed -i "s|^LLAMA_COMMIT=.*|LLAMA_COMMIT=$(COMMIT)|" $(TAGS)
	@test -z "$(ROCM)"       || sed -i "s|^ROCM_VERSION=.*|ROCM_VERSION=$(ROCM)|"     $(TAGS)
	@test -z "$(FEDORA)"     || sed -i "s|^FEDORA_VERSION=.*|FEDORA_VERSION=$(FEDORA)|" $(TAGS)
	@echo "TAGS updated -> $(IMAGE_NAME):$(BUILD)-rocm-$$(awk -F= -v k=ROCM_VERSION '$$1==k{print $$2}' $(TAGS))"
	@echo "next: make build && make deploy"

update: ## [maintainer] zero input: latest llama.cpp + ROCm; build, sync, deploy, label in git (commit + tag)
	python3 scripts/update.py

update-dry: ## [maintainer] preview make update (discover latest versions + diff + plan; nothing is changed)
	python3 scripts/update.py --dry-run
