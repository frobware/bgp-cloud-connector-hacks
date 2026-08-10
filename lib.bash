# shellcheck shell=bash
# Shared helpers. Source this, do not run it.
#
#   source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.bash"
#
# Nothing here is specific to any cloud. The aws- and gcp- scripts
# layer their own helpers on top via aws-lib.bash and gcp-lib.bash.
#
# On error handling: scripts keep `set -euo pipefail` as a backstop for
# the command nobody remembered to check. It is not the mechanism, it is
# the safety net underneath the mechanism. Anything whose failure you
# have actually thought about goes through `try` or `phase`, both of
# which suspend -e the same way `if ! cmd` does.

# Every script that sources this gets the same defaults, overridable
# from the environment so callers can set them once and forget.
# No confirmation flag, because nothing here prompts. These scripts are
# free-range: they do what you asked without stopping to check, and
# --dry-run is how you rehearse. A prompt is only a guard if the person
# reading it knows something the script does not, and here the script
# knows more -- it has already checked for name collisions, existing
# resources and the rest.
dry_run=false

_failures=()

warn() { printf '%s\n' "$*" >&2; }
info() { printf '%s\n' "$*"; }

# Stop now. For preconditions, not for step failures -- a step failure
# that should not stop the run belongs in `phase`.
die() {
    printf 'Error: %s\n' "$1" >&2
    shift
    for line in "$@"; do printf '  %s\n' "$line" >&2; done
    exit 1
}

# Parse the flags every script here accepts, so they stay consistent.
# Anything unrecognised lands in rest for the caller to deal with.
#
# Sets globals rather than echoing them: callers would reach for
# $(parse_common_args "$@"), and a subshell cannot set dry_run.
rest=()
parse_common_args() {
    rest=()
    for arg in "$@"; do
        case "$arg" in
            --dry-run) dry_run=true ;;
            *)         rest+=("$arg") ;;
        esac
    done
}

# The common case: a script taking only the shared flags.
parse_args_only_common() {
    parse_common_args "$@"
    [ ${#rest[@]} -eq 0 ] && return 0
    die "unknown option: ${rest[0]}" "Usage: ${0##*/} [--dry-run]"
}

# Fail once listing everything missing, rather than making the caller
# rerun to discover the next unset variable.
require_env() {
    local missing=()
    for var in "$@"; do
        [ -n "${!var:-}" ] || missing+=("$var")
    done
    [ ${#missing[@]} -eq 0 ] && return 0
    die "missing required environment: ${missing[*]}" \
        "Set them and try again."
}

require_cmd() {
    local missing=()
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    [ ${#missing[@]} -eq 0 ] && return 0
    die "not on PATH: ${missing[*]}" \
        "You are probably outside the dev shell; try: direnv allow"
}

# Run a command, honouring dry_run, returning its status rather than
# exiting. Callers decide what a failure means.
try() {
    if [ "$dry_run" = true ]; then
        info "  would run: $*"
        return 0
    fi
    "$@"
}

# Poll a predicate until it succeeds, or give up and say so.
#
#   wait_until 600 10 "endpoints to go away" endpoints_gone "$rs"
#
# The predicate is any command, so callers pass a function name and its
# arguments. This exists because the hand-rolled seq/sleep loops it
# replaces fell out silently when they exhausted, and the script then
# carried on as though the wait had succeeded. Returning non-zero on
# timeout means the caller has to decide, which is the point.
wait_until() {
    local timeout="$1" interval="$2" desc="$3"
    shift 3
    local deadline=$(( SECONDS + timeout ))
    while true; do
        if "$@"; then
            return 0
        fi
        if [ "$SECONDS" -ge "$deadline" ]; then
            warn "  timed out after ${timeout}s waiting for $desc"
            return 1
        fi
        sleep "$interval"
    done
}

# Run a named step, record a failure, and carry on. Teardown needs this:
# stopping at the first error is how orphaned resources happen.
phase() {
    local name="$1"; shift
    info "--- $name ---"
    if ! "$@"; then
        _failures+=("$name")
        warn "  FAILED: $name"
    fi
    info ""
}

# Note a failure discovered outside a phase, e.g. a post-run check.
fail() {
    _failures+=("$1")
    warn "  FAILED: $1"
}

# The fail-fast counterpart to phase, for work that builds on itself.
# Teardown wants to continue past a failure; creation does not, because
# every later step assumes the earlier ones happened.
step() {
    local name="$1"; shift
    local start=$SECONDS
    info "--- $name ---"
    if ! "$@"; then
        die "$name failed" \
            "Nothing after this point ran. See above for the command output."
    fi
    info "  ok ($((SECONDS - start))s)"
}

# Run a check, remember whether it passed, always return 0 so a run of
# checks reports everything wrong at once instead of one thing per
# invocation. Pair with abort_if_failed.
check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        info "  ok    $desc"
    else
        _failures+=("$desc")
        warn "  FAIL  $desc"
    fi
    return 0
}

# Same, but for checks whose failure is worth knowing and not worth
# stopping for.
check_warn() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        info "  ok    $desc"
    else
        warn "  WARN  $desc"
    fi
    return 0
}

abort_if_failed() {
    [ ${#_failures[@]} -eq 0 ] && return 0
    warn ""
    warn "${#_failures[@]} precondition(s) failed:"
    for f in "${_failures[@]}"; do warn "  $f"; done
    die "refusing to start" \
        "Nothing has been created, so there is nothing to clean up."
}

# Retry a command that fails for reasons that are nobody's fault.
# Registry pulls in particular: today's log gather died on an
# unexpected EOF from cdn01.quay.io mid-blob.
retry() {
    local attempts="$1" delay="$2"; shift 2
    local n=1
    while true; do
        if "$@"; then
            return 0
        fi
        if [ "$n" -ge "$attempts" ]; then
            warn "  giving up after $n attempt(s)"
            return 1
        fi
        warn "  attempt $n/$attempts failed, retrying in ${delay}s"
        n=$((n + 1))
        sleep "$delay"
    done
}

failure_count() { printf '%s' "${#_failures[@]}"; }

# Final word, and the exit status. Call this last.
report() {
    if [ "$dry_run" = true ]; then
        info "Dry run only, nothing was changed."
        return 0
    fi
    if [ ${#_failures[@]} -eq 0 ]; then
        info "Done."
        return 0
    fi
    warn "Finished with ${#_failures[@]} failure(s):"
    for f in "${_failures[@]}"; do warn "  $f"; done
    return 1
}

# Nothing cloud-specific lives here. require_aws is in aws-lib.bash,
# require_gcp in gcp-lib.bash; scripts source the lib for their cloud,
# which sources this one.
