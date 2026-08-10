{
  description = "Development shell for bgp-cloud-connector-hacks";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          name = "bgp-cloud-connector-hacks";

          # Not here on purpose: openshift-install and ccoctl. Both must
          # match the release payload you are installing, not whatever
          # nixpkgs happens to carry, so they come out of the payload
          # itself and you point OPENSHIFT_INSTALL and CCOCTL at them.
          #
          # aws-saml.py is also absent. It comes from a Red Hat GitLab
          # repo that needs the VPN, and aws-install-saml builds it its
          # own venv, taking gssapi and python-ldap from nixpkgs because
          # they will not compile against the Nix krb5 headers.
          # The list is deliberately explicit rather than minimal. Half
          # the point is to show somebody on Fedora what this expects,
          # so a tool the scripts invoke belongs here even when it
          # happens to be installed everywhere.
          #
          # Not listed, because mkShell's stdenv already provides them:
          # coreutils, gnutar, gnumake, gnused, gawk, gnugrep,
          # findutils. Verified by resolving tar and make inside the
          # shell and finding store paths rather than host paths.
          packages = with pkgs; [
            awscli2
            google-cloud-sdk # gcloud, for the gcp- scripts
            openshift # oc
            jq
            pass # reads the account id from a pass entry
            gnupg # pass cannot decrypt without it, and it is easy to
            # miss because a nix user profile usually supplies gpg, so
            # the shell looks complete when it is not
            curl # get-openshift-install require_cmd's it
            krb5 # kinit, klist
            go_1_26 # cmd/aws-credential-process
            shellcheck
            shfmt # make fmt
            git

            # aws-create-cluster writes a .envrc into each cluster
            # directory and allows it, so cd-ing into one exports the
            # right KUBECONFIG. It degrades to just writing the file if
            # direnv is missing, so this is a convenience rather than a
            # requirement: these scripts have to work on other people's
            # machines too.
            direnv

            # aws-create-cluster validates install-config.yaml by
            # parsing it, so pyyaml is a hard requirement rather than a
            # convenience. Without this the shell borrows whatever
            # python is on the host and the check passes or fails by
            # accident.
            (python3.withPackages (ps: with ps; [ pyyaml ]))

            # ccoctl comes out of the release payload as a dynamically
            # linked binary built for a generic Linux, which NixOS
            # cannot execute: PT_INTERP points at a stub loader. Patch
            # it after extracting:
            #
            #   interp=$(patchelf --print-interpreter "$(readlink -f "$(command -v ls)")")
            #   patchelf --set-interpreter "$interp" \
            #       --set-rpath "$(dirname "$interp")" ccoctl-<version>
            patchelf
          ];

          shellHook = ''
            # The scripts are namespaced by cloud already, so putting
            # them on PATH costs nothing and saves typing ./ everywhere.
            export PATH="$PWD:$PATH"
          '';
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixpkgs-fmt);
    };
}
