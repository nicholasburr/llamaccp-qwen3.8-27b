# fedora-ai — llama.cpp (ROCm gfx1151) image build & container deployment.
#
# Tag scheme
# ----------
# TAGS is the single source of truth. The image tag is computed, never
# hand-typed:
#
#     IMAGE_TAG = <LLAMA_BUILD>-rocm-<ROCM_VERSION>     e.g. b10896-rocm-7.2.4
#
# `make build` tags the image $(IMAGE) plus $(IMAGE_NAME):latest; `make sync`
# rewrites every image reference in the three deployment methods (script /
# compose / quadlet) to the current tag so all of them stay in lockstep.
#
# Deploying a new tag:
#     make new-build BUILD=b12345 COMMIT=<sha>     # point TAGS at a new build
#     make build                                   # build + tag the image
#     make deploy [METHOD=compose|script|quadlet]  # recreate the container
#
# Reusing an image that already exists locally (no rebuild):
#     make tag FROM=rocm-7.2.4
#
# Run `make help` for the target list. See README.md "Tagging & deployment".

SHELL := /bin/bash
MAKEFLAGS += --no-builtin-rules

TAGS := TAGS

# Read KEY=VALUE from TAGS.
tagvar = $(strip $(shell awk -F= -v k="$(1)" '$$1==k{print $$2; exit}' $(TAGS) 2>/dev/null))

IMAGE_NAME     := $(call tagvar,IMAGE_NAME)
LLAMA_BUILD    := $(call tagvar,LLAMA_BUILD)
LLAMA_COMMIT   := $(call tagvar,LLAMA_COMMIT)
ROCM_VERSION   := $(call tagvar,ROCM_VERSION)
FEDORA_VERSION := $(call tagvar,FEDORA_VERSION)
GPU_TARGET     := $(call tagvar,GPU_TARGET)
MODEL          := $(call tagvar,MODEL)

IMAGE_TAG := $(LLAMA_BUILD)-rocm-$(ROCM_VERSION)
IMAGE     := $(IMAGE_NAME):$(IMAGE_TAG)

CONTAINERFILE := containers/Containerfile.llama-server
QUADLET_SRC   := config/containers/systemd/llama-server
QUADLET_DST   := /etc/containers/systemd/llama-server
DEPLOY_FILES  := scripts/llama-server.sh \
                 podman-compose.yml \
                 $(QUADLET_SRC)/llama-server.build \
                 $(QUADLET_SRC)/llama-server.container

METHOD ?= compose

.PHONY: help show verify sync build tag new-build deploy deploy-compose deploy-script deploy-quadlet down stop logs status

help: ## Show the available targets
	@echo "fedora-ai — active image: $(IMAGE)"
	@echo
	@grep -hE '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | \
		awk '{ n=index($$0, ":"); h=index($$0, "## "); \
		       printf "  make %-42s %s\n", substr($$0,1,n-1), substr($$0,h+3) }'

show: ## Show the active tag and every image reference in the repo
	@echo "active image : $(IMAGE)"
	@echo "llama.cpp    : $(LLAMA_BUILD)  (commit $(LLAMA_COMMIT))"
	@echo "rocm/fedora  : $(ROCM_VERSION) / f$(FEDORA_VERSION)  (gpu target $(GPU_TARGET))"
	@echo "model        : $(MODEL)"
	@echo
	@echo "image references in deploy files:"
	@grep -HnoE '$(IMAGE_NAME):[A-Za-z0-9._-]+' $(DEPLOY_FILES) | sed 's/^/  /'

verify: ## Fail unless every deploy file references exactly $(IMAGE)
	@refs=$$(grep -hoE '$(IMAGE_NAME):[A-Za-z0-9._-]+' $(DEPLOY_FILES) | sort -u); \
	n=$$(printf '%s\n' "$$refs" | grep -c . || true); \
	echo "deploy files reference $$n distinct tag(s):"; \
	printf '%s\n' "$$refs" | sed 's/^/  /'; \
	if [ "$$n" -eq 1 ] && [ "$$refs" = "$(IMAGE)" ]; then \
		echo "OK — all methods in sync with $(IMAGE)"; \
	else \
		echo "DRIFT — expected only $(IMAGE); fix with: make sync"; exit 1; \
	fi

sync: ## Rewrite image tag, quadlet build args and model ref in all methods to match TAGS
	@echo "syncing deploy files -> $(IMAGE)"; \
	for f in $(DEPLOY_FILES); do \
		sed -i -E "s|$(IMAGE_NAME):[A-Za-z0-9._-]+|$(IMAGE)|g" $$f; \
	done; \
	sed -i -E \
		-e "s|^BuildArg=FEDORA_VERSION=.*|BuildArg=FEDORA_VERSION=$(FEDORA_VERSION)|" \
		-e "s|^BuildArg=ROCM_VERSION=.*|BuildArg=ROCM_VERSION=$(ROCM_VERSION)|" \
		-e "s|^BuildArg=GPU_TARGET=.*|BuildArg=GPU_TARGET=$(GPU_TARGET)|" \
		-e "s|^BuildArg=BRANCH=.*|BuildArg=BRANCH=$(LLAMA_COMMIT)|" \
		$(QUADLET_SRC)/llama-server.build; \
	old=$$(awk -F'"' '/LLAMA_ARG_HF_REPO/{print $$2; exit}' podman-compose.yml); \
	if [ -n "$$old" ] && [ "$$old" != "$(MODEL)" ]; then \
		echo "syncing model ref: $$old -> $(MODEL)"; \
		for f in scripts/llama-server.sh podman-compose.yml $(QUADLET_SRC)/llama-server.container; do \
			sed -i "s|$$old|$(MODEL)|g" $$f; \
		done; \
	else \
		echo "model ref already in sync"; \
	fi
	@$(MAKE) --no-print-directory verify

build: ## Build the image as $(IMAGE) (+ latest), pinned to commit $(LLAMA_COMMIT)
	podman build -f $(CONTAINERFILE) \
		--build-arg FEDORA_VERSION=$(FEDORA_VERSION) \
		--build-arg ROCM_VERSION=$(ROCM_VERSION) \
		--build-arg BRANCH=$(LLAMA_COMMIT) \
		--build-arg GPU_TARGET=$(GPU_TARGET) \
		-t $(IMAGE) \
		-t $(IMAGE_NAME):latest \
		.

tag: ## Retag an existing local image as $(IMAGE), no rebuild: make tag FROM=rocm-7.2.4
	@test -n "$(FROM)" || { echo "usage: make tag FROM=<current-tag>   (e.g. FROM=rocm-7.2.4)"; exit 2; }
	podman tag $(IMAGE_NAME):$(FROM) $(IMAGE)
	podman tag $(IMAGE_NAME):$(FROM) $(IMAGE_NAME):latest
	@podman images --format '{{.Repository}}:{{.Tag}}  ({{.Size}})' | grep -F "$(IMAGE_NAME):" | sed 's/^/  /'

new-build: ## Point TAGS at a new llama.cpp build: make new-build BUILD=b12345 COMMIT=<sha> [ROCM=x.y.z] [FEDORA=n] [GPU_TARGET=...]
	@test -n "$(BUILD)" && test -n "$(COMMIT)" || { echo "usage: make new-build BUILD=b12345 COMMIT=<sha> [ROCM=x.y.z] [FEDORA=n] [GPU_TARGET=...]"; exit 2; }
	@sed -i "s|^LLAMA_BUILD=.*|LLAMA_BUILD=$(BUILD)|" $(TAGS)
	@sed -i "s|^LLAMA_COMMIT=.*|LLAMA_COMMIT=$(COMMIT)|" $(TAGS)
	@test -z "$(ROCM)"       || sed -i "s|^ROCM_VERSION=.*|ROCM_VERSION=$(ROCM)|"     $(TAGS)
	@test -z "$(FEDORA)"     || sed -i "s|^FEDORA_VERSION=.*|FEDORA_VERSION=$(FEDORA)|" $(TAGS)
	@test -z "$(GPU_TARGET)" || sed -i "s|^GPU_TARGET=.*|GPU_TARGET=$(GPU_TARGET)|"    $(TAGS)
	@echo "TAGS updated -> $(IMAGE_NAME):$(BUILD)-rocm-$$(awk -F= -v k=ROCM_VERSION '$$1==k{print $$2}' $(TAGS))"
	@echo "next: make build && make deploy"

deploy: sync ## Deploy $(IMAGE): sync, then start via METHOD (compose [default] | script | quadlet)
	@if [ "$(METHOD)" != "compose" ] && [ "$(METHOD)" != "script" ] && [ "$(METHOD)" != "quadlet" ]; then \
		echo "unknown METHOD=$(METHOD) (use compose, script or quadlet)"; exit 2; \
	fi
	@$(MAKE) --no-print-directory deploy-$(METHOD)

deploy-compose: ## Recreate the container with podman compose (requires the podman-compose ipc patch — scripts/fedora-setup.sh)
	podman compose up -d

deploy-script: ## (Re)start the container with scripts/llama-server.sh (podman run --replace)
	bash scripts/llama-server.sh

deploy-quadlet: ## Install quadlet units into $(QUADLET_DST) and start (requires root)
	install -d -m 0755 $(QUADLET_DST)
	install -m 0644 $(QUADLET_SRC)/llama-server.build     $(QUADLET_DST)/llama-server.build
	install -m 0644 $(QUADLET_SRC)/llama-server.container $(QUADLET_DST)/llama-server.container
	systemctl daemon-reload
	systemctl enable --now llama-server-build.service
	systemctl enable --now llama-server.service

down: ## Stop and remove the container (compose)
	podman compose down

stop: ## Stop the container (keep it)
	podman stop llama-server

logs: ## Follow the container logs
	podman logs -f llama-server

status: ## Container state + tag drift check
	@podman ps -a --filter name=llama-server --format '  {{.Names}} | {{.Image}} | {{.Status}}'
	@$(MAKE) --no-print-directory verify

