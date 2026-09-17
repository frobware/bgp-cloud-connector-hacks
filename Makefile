scripts := $(wildcard aws-*) $(wildcard azure-*) $(wildcard gcp-*) get-openshift-install lib.bash

.DEFAULT_GOAL := check

.PHONY: check
check: shellcheck syntax ## run every check

.PHONY: shellcheck
shellcheck: ## shellcheck every script
	shellcheck -x $(scripts)

.PHONY: syntax
syntax: ## bash -n every script
	@for f in $(scripts); do \
	    bash -n "$$f" || exit 1; \
	done
	@echo "syntax ok: $(words $(scripts)) files"


.PHONY: list
list: ## show what gets checked
	@printf '%s\n' $(scripts)

.PHONY: help
help: ## show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
	    | sort \
	    | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'
