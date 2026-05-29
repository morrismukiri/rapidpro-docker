# RapidPro v9 image build + verification harness.
# Local engine is podman (no Docker daemon); CI can set ENGINE=docker.

ENGINE            ?= podman
REGISTRY          ?= docker.io/morrismukiri
PLATFORMS         ?= linux/arm64                 # publish sets linux/amd64,linux/arm64

# Pinned versions (v9 line). Override on the CLI if needed.
RAPIDPRO_VERSION  ?= v9.0.0
RAPIDPRO_REPO     ?= rapidpro/rapidpro
NODE_MAJOR        ?= 20
# Go components must match the app's DB schema (v9.0.0 stable), NOT the 9.3 dev line.
MAILROOM_VERSION  ?= 9.0.1
COURIER_VERSION   ?= 9.0.1
INDEXER_VERSION   ?= 9.0.0
ARCHIVER_VERSION  ?= 9.0.0

APP_TAG           ?= $(RAPIDPRO_VERSION)
MAJOR_TAG         ?= v9

.PHONY: help images build-app build-mailroom build-courier build-indexer build-archiver \
        publish-app publish-go push clean \
        verify verify-static verify-image verify-kind

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  %-18s %s\n", $$1, $$2}'

images: build-app build-mailroom build-courier build-indexer build-archiver ## Build all 5 images (native arch)

build-app: ## Build the RapidPro app image
	$(ENGINE) build \
	  --build-arg RAPIDPRO_VERSION=$(RAPIDPRO_VERSION) \
	  --build-arg RAPIDPRO_REPO=$(RAPIDPRO_REPO) \
	  --build-arg NODE_MAJOR=$(NODE_MAJOR) \
	  -t $(REGISTRY)/rapidpro:$(APP_TAG) -t $(REGISTRY)/rapidpro:$(MAJOR_TAG) \
	  -f Dockerfile .

# $1=image $2=binary $3=repo $4=version $5=port
define build_go
	$(ENGINE) build \
	  --build-arg BINARY=$(2) --build-arg REPO=$(3) --build-arg VERSION=$(4) --build-arg PORT=$(5) \
	  -t $(REGISTRY)/$(1):v$(4) -t $(REGISTRY)/$(1):$(MAJOR_TAG) \
	  -f go-services/Dockerfile go-services
endef

build-mailroom: ## Build mailroom
	$(call build_go,mailroom,mailroom,nyaruka/mailroom,$(MAILROOM_VERSION),8090)
build-courier: ## Build courier
	$(call build_go,courier,courier,nyaruka/courier,$(COURIER_VERSION),8080)
build-indexer: ## Build rp-indexer
	$(call build_go,rp-indexer,rp-indexer,nyaruka/rp-indexer,$(INDEXER_VERSION),8080)
build-archiver: ## Build rp-archiver
	$(call build_go,rp-archiver,rp-archiver,nyaruka/rp-archiver,$(ARCHIVER_VERSION),8080)

# --- multi-arch publish (podman manifest) -------------------------------------
publish-app: ## Build+push multi-arch app manifest (set PLATFORMS=linux/amd64,linux/arm64)
	-$(ENGINE) manifest rm $(REGISTRY)/rapidpro:$(APP_TAG) 2>/dev/null
	-$(ENGINE) rmi -f $(REGISTRY)/rapidpro:$(APP_TAG) 2>/dev/null
	$(ENGINE) build --platform $(PLATFORMS) --manifest $(REGISTRY)/rapidpro:$(APP_TAG) \
	  --build-arg RAPIDPRO_VERSION=$(RAPIDPRO_VERSION) --build-arg RAPIDPRO_REPO=$(RAPIDPRO_REPO) \
	  --build-arg NODE_MAJOR=$(NODE_MAJOR) -f Dockerfile .
	$(ENGINE) manifest push --all $(REGISTRY)/rapidpro:$(APP_TAG) docker://$(REGISTRY)/rapidpro:$(APP_TAG)

clean: ## Remove the local kind cluster
	kind delete cluster --name rapidpro-verify 2>/dev/null || true

# --- verification harness (Part D) --------------------------------------------
verify: verify-static verify-image verify-kind ## Run the full verification harness

verify-static: ## L0: hadolint + helm lint/template/kubeconform + helm-unittest + conftest
	./scripts/verify-static.sh

verify-image: ## L1: build + container-structure-test + trivy (engine-agnostic via tar)
	./scripts/verify-image.sh

verify-kind: ## L2: kind install + helm test + celery isolation + playwright
	./scripts/verify-kind.sh
