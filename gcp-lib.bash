# shellcheck shell=bash
# GCP-specific helpers, layered over lib.bash. Source this, do not run
# it.
#
# Two credentials are in play on GCP, and they are not the same thing:
#
#   - gcloud's own login (gcloud auth login) drives the queries these
#     scripts make: DNS zones, record sets, leftover service accounts.
#     It is a user credential and its refresh token can go stale, at
#     which point every gcloud call fails with invalid_grant.
#   - GOOGLE_CREDENTIALS names a service-account key file, and that is
#     what openshift-install consumes. Keys do not expire, so unlike
#     AWS there is no session-shorter-than-the-install race.
#
# require_gcp checks the first. The scripts that run the installer
# check the second themselves, in preflight, where a failure lists
# alongside everything else that is wrong.

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.bash"

# The project id is deliberately not defaulted. Like the AWS account
# id, it is not exactly a secret but it is nobody else's business, so
# it lives in .envrc.local (which .gitignore keeps uncommitted), not
# here.
# The managed zone serving a domain, by name, public zones only.
# Split-horizon projects hold public and private zones for the same
# dnsName, and the installs here publish externally, so collision
# checks and audits must look at the public one -- an unfiltered
# lookup with head -1 picks arbitrarily. Prints the zone name, or
# nothing when no public zone serves the domain. Fails when the
# listing itself fails or more than one public zone matches, because
# picking one of those silently means checking the wrong place.
zone_for_domain() {
    local zones
    zones="$(gcloud dns managed-zones list --project "$1" \
        --filter "dnsName=${2}. AND visibility=public" \
        --format 'value(name)')" || return 1
    [ "$(printf '%s' "$zones" | grep -c .)" -le 1 ] || return 1
    printf '%s' "$zones"
}

require_gcp() {
    require_cmd gcloud
    [ -n "${GCP_PROJECT:-}" ] || die "GCP_PROJECT is not set" \
        "Name the project, e.g. in .envrc.local:" \
        "  export GCP_PROJECT=<project-id>"
    # Repeat what gcloud said rather than guessing why it failed. A stale
    # refresh token, a 503 and an exhausted read quota fail this probe
    # identically, so naming any one of them unconditionally sends you off
    # fixing something that was never wrong.
    #
    # The quota one is not hypothetical: cloudresourcemanager.googleapis.com
    # /read_requests runs out at 2400 and takes the whole teardown down with
    # it, while the credential is perfectly good. So the advice below is a
    # test that tells the causes apart rather than a guess at which it is.
    local err
    capture err gcloud projects describe "$GCP_PROJECT" --format='value(projectId)' && return 0
    die "cannot read project $GCP_PROJECT as $(gcloud config get-value account 2>/dev/null)" \
        "gcloud said:" \
        "${err:-(gcloud failed without saying anything)}" \
        "" \
        "That probe fails the same way whatever the cause, so find out which" \
        "before changing anything:" \
        "  gcloud auth print-access-token >/dev/null && echo 'credential is fine'" \
        "" \
        "A token that prints means the credential is not the problem. Read the" \
        "message above for a quota_metric or rateLimitExceeded, which is a rate" \
        "limit: it clears on its own within a minute, so wait and rerun." \
        "" \
        "Only invalid_grant means the login has gone stale:" \
        "  gcloud auth login"
}
