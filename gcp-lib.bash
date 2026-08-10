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
require_gcp() {
    require_cmd gcloud
    [ -n "${GCP_PROJECT:-}" ] || die "GCP_PROJECT is not set" \
        "Name the project, e.g. in .envrc.local:" \
        "  export GCP_PROJECT=<project-id>"
    gcloud projects describe "$GCP_PROJECT" --format='value(projectId)' >/dev/null 2>&1 && return 0
    die "cannot read project $GCP_PROJECT as $(gcloud config get-value account 2>/dev/null)" \
        "The login token may have gone stale (invalid_grant). Renew it:" \
        "  gcloud auth login"
}
