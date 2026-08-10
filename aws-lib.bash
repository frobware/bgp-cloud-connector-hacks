# shellcheck shell=bash
# AWS-specific helpers, layered over lib.bash. Source this, do not run
# it. Scripts that never touch AWS credentials source lib.bash instead.

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.bash"

require_aws() {
    aws sts get-caller-identity >/dev/null 2>&1 && return 0
    die "no usable AWS credentials" \
        "Select a profile, e.g. AWS_PROFILE=saml ${0##*/}" \
        "Available: $(aws configure list-profiles 2>/dev/null | tr '\n' ' ')" \
        "Or mint fresh ones: aws-login --force"
}
