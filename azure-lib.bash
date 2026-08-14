# shellcheck shell=bash
# Azure-specific helpers, layered over lib.bash. Source this, do not run
# it.
#
# Two credentials are in play on Azure, and as on GCP they are not the
# same thing:
#
#   - your az login is a user credential, and it drives the queries
#     these scripts make: DNS zones, resource groups, quota. It is
#     interactive and it expires.
#   - ~/.azure/osServicePrincipal.json holds a service principal, and
#     that is what openshift-install consumes. The path and the
#     AZURE_AUTH_LOCATION override are the installer's own, read out of
#     pkg/asset/installconfig/azure/session.go rather than invented
#     here, so nothing has to be told where to look.
#
# The installer will happily prompt for those four fields and write the
# file itself, which is why nothing here mints one silently: a prompt
# mid-install is how you end up with credentials nobody recorded.
#
# require_azure checks the first. The scripts that run the installer
# check the second themselves, in preflight, where a failure lists
# alongside everything else that is wrong.

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.bash"

# Where openshift-install looks for the service principal, and the
# variable it reads to be told otherwise.
azure_credentials_file() {
    printf '%s' "${AZURE_AUTH_LOCATION:-$HOME/.azure/osServicePrincipal.json}"
}

# The subscription az is pointed at right now. Not defaulted anywhere:
# the authority is the credentials file, and the scripts compare the two
# rather than picking one, because a preflight that queries a different
# subscription from the one being installed into reports the wrong
# answer confidently.
azure_active_subscription() {
    az account show --query id -o tsv 2>/dev/null
}

# The resource group holding the public DNS zone for a domain, by exact
# zone name. Azure keeps private zones under a different provider
# entirely, so unlike the GCP equivalent there is no split-horizon
# ambiguity to filter out; what remains is a zone of the same name in
# two resource groups, which is possible and which we refuse rather than
# resolve. Prints the group, or nothing when no zone serves the domain.
zone_resource_group() {
    local groups
    groups="$(az network dns zone list --query "[?name=='${1}'].resourceGroup" -o tsv)" || return 1
    [ "$(printf '%s' "$groups" | grep -c .)" -le 1 ] || return 1
    printf '%s' "$groups"
}

require_azure() {
    require_cmd az
    # Repeat what az said rather than naming a cause we did not observe.
    # An expired refresh token, a revoked guest account and an
    # unreachable login endpoint all fail this identically.
    local err
    capture err az account show --output none && return 0
    die "cannot read the current Azure account" \
        "az said:" \
        "${err:-(az failed without saying anything)}" \
        "Log in and pick the subscription:" \
        "  az login"
}
