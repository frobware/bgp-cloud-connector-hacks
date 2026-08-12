# Checks for the scripts in this repo. There is nothing to build: the
# bash is the artefact, and the one Go program runs via go run.

# aws-credential-process is the binary go build leaves behind, not a
# script, so keep it out of the shell checks.
# get-openshift-install is named by hand: it has no aws- prefix, and a
# wildcard that missed it once let a bug ship unlinted.
scripts := $(filter-out aws-credential-process,$(wildcard aws-*)) $(wildcard gcp-*) get-openshift-install lib.bash

.DEFAULT_GOAL := check

.PHONY: check
check: shellcheck syntax vet test ## run every check

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

.PHONY: test
test: ## go test the Go helpers
# Linting without running is how two bugs in this repo's history shipped.
	go test ./...

.PHONY: fmt
fmt: ## reformat the scripts with shfmt and the Go with gofmt
# Not part of check: reformatting is a decision, not a verification,
# and a target that rewrites your working tree should be asked for.
#
# Formatting is reformatted here rather than asserted in check because
# nothing but a person ever runs check: no CI, no hook. A check whose
# only remedy is "go and run the formatter" is a slower way of running
# the formatter. go fmt is deliberately not used, since it exits 0
# whatever it finds and would be useless in check anyway.
	shfmt -w -i 4 -ci $(scripts)
	gofmt -w $$(go list -f '{{.Dir}}' ./...)

.PHONY: list
list: ## show what gets checked
	@printf '%s\n' $(scripts)

.PHONY: help
help: ## show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
	    | sort \
	    | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'
