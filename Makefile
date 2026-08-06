# Checks for the scripts in this repo. There is nothing to build: the
# bash is the artefact, and the one Go program runs via go run.

# aws-credential-process is the binary go build leaves behind, not a
# script, so keep it out of the shell checks.
# get-openshift-install is named by hand: it has no aws- prefix, and a
# wildcard that missed it once let a bug ship unlinted.
scripts := $(filter-out aws-credential-process,$(wildcard aws-*)) get-openshift-install lib.bash

.DEFAULT_GOAL := check

.PHONY: check
check: shellcheck syntax vet ## run every check

.PHONY: shellcheck
shellcheck: ## shellcheck every script
# -x so it follows the lib.bash source rather than warning about it.
	shellcheck -x $(scripts)

.PHONY: syntax
syntax: ## bash -n every script
# Catches what shellcheck cannot: whether bash will actually parse it.
	@for f in $(scripts); do \
	    bash -n "$$f" || exit 1; \
	done
	@echo "syntax ok: $(words $(scripts)) files"

.PHONY: vet
vet: ## go vet the Go helpers
	go vet ./...

.PHONY: fmt
fmt: ## reformat the scripts with shfmt
# Not part of check: reformatting is a decision, not a verification,
# and a target that rewrites your working tree should be asked for.
	shfmt -w -i 4 -ci $(scripts)

.PHONY: list
list: ## show what gets checked
	@printf '%s\n' $(scripts)

.PHONY: help
help: ## show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
	    | sort \
	    | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'
