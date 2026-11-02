# shellcheck shell=bash
# The ccoctl half of a Manual-mode install, shared by aws-create-cluster
# and gcp-create-cluster (with GCP_WIF=1). Source it after lib.bash.
#
# The functions read the caller's globals rather than taking them as
# arguments, because that is how both create scripts already pass them
# around: installer, ccoctl, bin_dir, cluster_dir and pull_secret.
# extract_credential_requests takes the cloud, the one thing that
# differs between callers.
#
# shellcheck disable=SC2154 # those globals are the callers'

ccoctl_runnable() { [ -x "$1" ] && "$1" --help >/dev/null 2>&1; }

ensure_ccoctl() {
    local release_image
    if ccoctl_runnable "$ccoctl"; then
        info "  ccoctl already present and runnable"
        return 0
    fi

    mkdir -p "$bin_dir"

    if [ ! -f "$ccoctl" ]; then
        release_image="$("$installer" version | awk '/release image/ {print $3}')"
        local cco_image
        # -a on every call. extract_ccoctl.sh omits it on the
        # --image-for lookup and falls back to ~/.docker/config.json,
        # which on a credsStore setup has no usable inline auth.
        cco_image="$(retry 3 10 oc adm release info \
            --registry-config="$pull_secret" \
            --image-for=cloud-credential-operator "$release_image")" || return 1
        info "  extracting ccoctl from $cco_image"
        ( cd "$bin_dir" && retry 3 10 oc image extract "$cco_image" \
            --file=/usr/bin/ccoctl -a "$pull_secret" ) || return 1
        chmod +x "$ccoctl"
    fi

    # The payload binary is dynamically linked for a generic Linux. On
    # NixOS PT_INTERP points at a stub loader that refuses to run it,
    # while ldd resolves everything and looks fine.
    if ! ccoctl_runnable "$ccoctl"; then
        command -v patchelf >/dev/null 2>&1 || {
            warn "  ccoctl will not execute and patchelf is not available"
            return 1
        }
        local interp
        interp="$(patchelf --print-interpreter "$(readlink -f "$(command -v ls)")")"
        info "  patching ccoctl interpreter to $interp"
        patchelf --set-interpreter "$interp" --set-rpath "$(dirname "$interp")" "$ccoctl"
        ccoctl_runnable "$ccoctl" || return 1
    fi
}

create_manifests() {
    if [ -d "$cluster_dir/manifests" ]; then
        info "  manifests already generated"
        return 0
    fi
    "$installer" create manifests --dir="$cluster_dir"
}

extract_credential_requests() {
    if [ -d "$cluster_dir/credreqs" ] && [ -n "$(ls -A "$cluster_dir/credreqs" 2>/dev/null)" ]; then
        info "  credential requests already extracted"
        return 0
    fi
    local release_image
    release_image="$("$installer" version | awk '/release image/ {print $3}')"
    mkdir -p "$cluster_dir/credreqs"
    # --included asks the payload to filter requests down to the
    # capabilities this install-config enables. It helps, but it is not
    # sufficient: measured against 4.22.8 it still emits the cluster-api
    # request on a default AWS install, apparently because that
    # CredentialsRequest carries no capability annotation for it to match
    # on. So the explicit drop below is doing the real work.
    retry 3 10 oc adm release extract --credentials-requests --included \
        --install-config="$cluster_dir/install-config.yaml.bak" \
        --registry-config="$pull_secret" \
        --cloud="$1" --to="$cluster_dir/credreqs" "$release_image"
    drop_requests_for_disabled_capabilities
    info "  $(find "$cluster_dir/credreqs" -type f | wc -l) credential request(s)"
}

# A CredentialsRequest whose component the cluster will not run is not
# merely useless, it is fatal. ccoctl turns it into a Secret targeting a
# namespace that never gets created, cluster-bootstrap retries that
# Secret forever, never writes kube-system/bootstrap, and bootstrapping
# times out at 45 minutes with a completely healthy control plane.
#
# Measured on 4.22.8, the offender is openshift-cluster-api-aws:
#
#   capability.openshift.io/name: CloudCredential
#   release.openshift.io/feature-gate: ClusterAPIMachineManagement
#
# It is gated by a feature gate but annotated with a capability. oc adm
# release extract --included filters on capabilities, sees
# CloudCredential is enabled, and keeps it. Meanwhile
# ClusterAPIMachineManagement is disabled in the default feature set, so
# openshift-cluster-api never exists and its Secret can never be
# created.
#
# Filtering on the feature-gate annotation catches it, and catches
# anything else the payload gates the same way, rather than hardcoding
# one filename. Dropping the request rather than the manifest also means
# no IAM role gets created for it.
#
# The assumption baked in here is that a gate-annotated request means a
# disabled gate. That holds today, but gates get promoted into the
# Default set while the annotation lingers on the request, and there is
# nothing to ask from out here: the default feature set lives inside the
# payload's binaries, not in any manifest we can read pre-install. So
# the day a promoted gate ships, this drops a request the cluster needs
# and its operator degrades for want of an IAM role. Hence parking the
# dropped requests in credreqs-dropped/ rather than deleting them: the
# person debugging that degradation finds the request, moves it back
# into credreqs/, and reruns ccoctl aws create-all in the cluster
# directory by hand.
drop_requests_for_disabled_capabilities() {
    local config="$cluster_dir/install-config.yaml.bak"
    local feature_set
    feature_set="$(awk '/^featureSet:/{print $2; exit}' "$config")"

    # A non-default feature set may well enable these, and we cannot
    # tell which from here, so keep everything and say so.
    if [ -n "$feature_set" ] && [ "$feature_set" != '""' ] && [ "$feature_set" != "Default" ]; then
        info "  featureSet is $feature_set, keeping all requests"
        return 0
    fi

    local f dropped=0
    for f in "$cluster_dir"/credreqs/*; do
        [ -f "$f" ] || continue
        local gate
        gate="$(awk -F': *' '/release\.openshift\.io\/feature-gate:/{print $2; exit}' "$f")"
        [ -n "$gate" ] || continue
        info "  dropping $(basename "$f"): gated by $gate, assumed not in the default feature set"
        mkdir -p "$cluster_dir/credreqs-dropped"
        mv "$f" "$cluster_dir/credreqs-dropped/"
        dropped=$((dropped + 1))
    done
    if [ "$dropped" -eq 0 ]; then
        info "  no feature-gated requests to drop"
    else
        info "  parked in credreqs-dropped/, in case a gate was promoted"
    fi
    return 0
}

merge_manifests() {
    cp "$cluster_dir"/ccoctl-output/manifests/* "$cluster_dir/manifests/"
    cp -a "$cluster_dir/ccoctl-output/tls" "$cluster_dir/"
}
