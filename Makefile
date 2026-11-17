# Kache workspace Makefile
# Enforces host throttling (-j 2) on local/ceres workstations and disables
# RUSTC_WRAPPER bootstrapping loops unless KACHE_SELF_HOST=1 is opted into.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

ifneq ($(KACHE_SELF_HOST),1)
export RUSTC_WRAPPER :=
endif

JOBS ?= 2
CARGO_BUILD_JOBS ?= $(JOBS)
export JOBS CARGO_BUILD_JOBS

COVERAGE_JSON ?= tmp/llvm-cov/coverage.json

.PHONY: help check ci fmt fmt-check clippy lint client-crates-check test \
	test-resource-guard-check audit deny coverage coverage-scope-check \
	helm-lint image-service image-service-print image-service-release \
	build build-service clean pin-actions pin-actions-check e2e e2e-s3

help: ## Show this help message
	@awk 'BEGIN { FS = ":.*##"; printf "Usage: make \033[36m<target>\033[0m\n" } \
		/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5); next } \
		/^[a-zA-Z_0-9-]+:.*##/ { printf "  \033[36m%-28s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

##@ Quality & Gates

check: fmt-check clippy client-crates-check test-resource-guard-check test ## Run all local quality checks (-j 2)

ci: fmt-check clippy client-crates-check image-service-print helm-lint test-resource-guard-check coverage ## Mirror the repository CI verification flow (-j 2)

fmt: ## Format workspace, command schema, and fuzz crate sources
	cargo fmt --all
	rustfmt crates/kache-client/src/commands.rs
	cargo fmt --manifest-path fuzz/Cargo.toml

fmt-check: ## Check formatting without modifying files
	cargo fmt --all -- --check
	rustfmt --check crates/kache-client/src/commands.rs
	cargo fmt --manifest-path fuzz/Cargo.toml -- --check

clippy: ## Run Rust clippy linter with warnings denied (-j 2)
	cargo clippy --workspace --locked -j $(JOBS) --all-targets -- -D warnings

lint: clippy ## Alias for clippy

client-crates-check: ## Verify client-only dependency graph without daemon async features (-j 2)
	cargo check --locked -j $(JOBS) -p kache-client -p kache-config -p kache-protocol -p kache-ipc --no-default-features
	cargo test --locked -j $(JOBS) -p kache-ipc --no-default-features

test: ## Run full workspace test suite under bounded resource guard (-j 2)
	./scripts/with-test-resources.sh cargo test --workspace --locked -j $(JOBS)

test-resource-guard-check: ## Verify raised-limit and bounded-thread fallback paths
	./scripts/test-with-test-resources.sh

audit: ## Run cargo-deny advisories, licenses, bans, and sources across every member
	@members=(); \
	while IFS= read -r member; do members+=("$$member"); done < <(./scripts/workspace-members.sh dirs); \
	repo_root="$$(pwd)"; \
	for member in "$${members[@]}" fuzz; do \
		echo "── cargo deny check ($$member) ──"; \
		( cd "$$repo_root/$$member" && cargo deny --config "$$repo_root/deny.toml" check ); \
	done

deny: audit ## Alias for audit

coverage: ## Collect and report workspace line coverage under tmp/llvm-cov/ (-j 2)
	./scripts/with-test-resources.sh cargo llvm-cov --all-features --workspace --locked -j $(JOBS) --no-report
	@packages=(); \
	while IFS= read -r package; do packages+=(--package "$$package"); done < <(./scripts/workspace-members.sh packages); \
	cargo llvm-cov report "$${packages[@]}" --html --output-dir tmp/llvm-cov; \
	cargo llvm-cov report "$${packages[@]}" --json --output-path tmp/llvm-cov/coverage.json
	$(MAKE) coverage-scope-check

coverage-scope-check: ## Verify coverage JSON contains every runtime-coverage-owned member
	./scripts/check-coverage-scope.sh "$(COVERAGE_JSON)"

helm-lint: ## Lint and strictly validate the kache-service Helm chart
	helm lint packaging/charts/kache-service
	helm template kache packaging/charts/kache-service \
		--set podAnnotations.example/annotation=set \
		--set podLabels.example/label=set \
		| kubeconform -strict -ignore-missing-schemas -summary

pin-actions: ## Pin every GitHub Actions uses: reference to a 40-char commit SHA
	GITHUB_TOKEN="$${GITHUB_TOKEN:-$$(gh auth token)}" pinact run

pin-actions-check: ## Verify every GitHub Actions uses: reference is SHA-pinned
	GITHUB_TOKEN="$${GITHUB_TOKEN:-$$(gh auth token)}" pinact run --check --verify

##@ Build & Packaging

build: ## Build release kache binary (-j 2)
	cargo build --release --locked -j $(JOBS)

build-service: ## Build release kache-service binary (-j 2)
	cargo build --release --locked -j $(JOBS) -p kache-service

image-service: ## Build the service container image locally
	docker buildx bake -f packaging/docker-bake.hcl service

image-service-print: ## Print the resolved service image bake plan
	docker buildx bake -f packaging/docker-bake.hcl --print service

image-service-release: ## Build and push the release service image
	docker buildx bake -f packaging/docker-bake.hcl release

e2e: ## Run checked-in gate end-to-end scenarios (-j 2)
	cargo build --release --locked -j $(JOBS) -p kache
	cargo build --release --locked -j $(JOBS) -p kache-e2e
	./target/release/kache-scenario \
		--kache ./target/release/kache \
		--scenarios ./scenarios \
		--select suite:e2e \
		--select tier:gate \
		--out tmp/e2e/results.json

e2e-s3: ## Run S3 remote integration tests against a throwaway local RustFS
	./scripts/e2e-s3.sh

clean: ## Remove build artifacts
	cargo clean
