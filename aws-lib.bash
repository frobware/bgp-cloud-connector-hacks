# shellcheck shell=bash
# AWS-specific helpers, layered over lib.bash. Source this, do not run
# it. Scripts that never touch AWS credentials source lib.bash instead.

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.bash"

# Expired credentials and an unreachable STS endpoint fail this the
# same way, and the remedy differs, so repeat what aws said instead of
# naming a cause we did not observe.
require_aws() {
    local err
    capture err aws sts get-caller-identity && return 0
    die "cannot verify AWS identity" \
        "aws said:" \
        "${err:-(aws failed without saying anything)}" \
        "Select a profile, e.g. AWS_PROFILE=saml ${0##*/}" \
        "Available: $(aws configure list-profiles 2>/dev/null | tr '\n' ' ')" \
        "Or mint fresh ones: aws-login --force"
}
