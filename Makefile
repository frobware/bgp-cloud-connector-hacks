scripts := $(filter-out aws-credential-process,$(wildcard aws-*)) $(wildcard azure-*) $(wildcard gcp-*) get-openshift-install lib.bash

.DEFAULT_GOAL := check

.PHONY: check
check: shellcheck syntax vet test ## run every check

.PHONY: shellcheck
shellcheck: ## shellcheck every script
	shellcheck -x $(scripts)

.PHONY: syntax
syntax: ## bash -n every script
	@for f in $(scripts); do \
	    bash -n "$$f" || exit 1; \
	done
	@echo "syntax ok: $(words $(scripts)) files"

.PHONY: vet
vet: ## go vet the Go helpers
	go vet ./...

.PHONY: test
test: ## go test the Go helpers
	go test ./...

.PHONY: fmt
fmt: ## gofmt the Go sources
	gofmt -w $$(go list -f '{{.Dir}}' ./...)

.PHONY: list
list: ## show what gets checked
	@printf '%s\n' $(scripts)

.PHONY: help
help: ## show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
	    | sort \
	    | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'
