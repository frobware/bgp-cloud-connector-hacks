# bgp-cloud-connector-hacks

Scaffolding for developing bgp-cloud-connector against a real cloud,
until the rosa-bgp Terraform is available and most of this can be
deleted.

Everything here is prefixed by cloud: `aws-`, `azure-` and `gcp-`.
`lib.bash` is shared and deliberately knows nothing about any
particular cloud; `aws-lib.bash`, `azure-lib.bash` and `gcp-lib.bash`
layer the cloud-specific helpers on top, and scripts source the lib
for their cloud.

## Getting started

Put the repo on your PATH, since the names are already namespaced:

```
export PATH="$PWD:$PATH"
```

You need the VPN for anything that talks to Red Hat, and a Kerberos
ticket for anything that mints credentials.

```
aws-install-saml                  # once per machine

export AWS_ACCOUNT_PASS=<your-pass-entry>      # first line is the account id
export AWS_ROLE=<account-id>-openshift-installer-restricted

kinit you@IPA.REDHAT.COM
aws-login                         # skips if the current session still works
export AWS_PROFILE=saml
```

`AWS_ACCOUNT_PASS` names a `pass` entry whose first line is the account
id. Neither the id nor the entry name is baked into any script here, and
neither belongs in this file: account numbers and role names are not
secrets exactly, but they are nobody else's business.

Put your real values in `.envrc.local`, which `.envrc` sources if it
exists. Because this repo's `.gitignore` denies by default, any file not
listed there is ignored, so `.envrc.local` cannot be committed by
accident:

```
export AWS_ACCOUNT_PASS=rhat/aws/some-entry
export AWS_ROLE=012345678901-openshift-installer-restricted
export AWS_SESSION_DURATION=3600
```

`AWS_ACCOUNT` works too if you would rather say the number out loud.

Note the role. `poweruser` cannot create an OIDC provider, so `ccoctl`
fails partway through an install with `iam:CreateOpenIDConnectProvider
... AccessDenied`. You want the openshift-installer-restricted role,
and it caps sessions at 3600 seconds where poweruser allows 43200.
`aws-login` retries at 3600 by itself rather than making you work that
out from the error.

## What is here

| | |
|:---|:---|
| `lib.bash` | Shared helpers. Source it, do not run it. |
| `aws-lib.bash`, `azure-lib.bash`, `gcp-lib.bash` | Cloud-specific helpers layered over `lib.bash` |
| `aws-install-saml` | Builds `~/.venvs/aws-saml` and installs Red Hat's `aws-saml.py`. Rerun it after a Python bump, since the venv points into the Nix store without a GC root. |
| `aws-login` | Mints credentials into the `saml` profile, skipping if the current ones still work |
| `get-openshift-install` | Fetches `openshift-install` from the mirror. No `aws-` prefix: it is the same binary whichever cloud you point it at. |
| `aws-create-cluster` | Builds a cluster. Preflights everything first and owns the whole sequence. |
| `aws-create-install-config` | Writes an install-config.yaml. Three masters by default, for the reason below. |
| `aws-create-route-servers` | Creates the AWS Route Servers the operator expects to discover |
| `aws-list-route-servers` | Shows every route server in a region, flagging orphans |
| `aws-delete-route-servers` | Tears them down again |
| `aws-destroy-cluster` | Full teardown, including what `openshift-install destroy` leaves behind |
| `cmd/aws-credential-process` | Credentials that refresh themselves. See below. |
| `azure-installer-credentials` | One-time: the service principal `openshift-install` needs, if you are allowed to make one |
| `azure-create-cluster` | Builds an Azure cluster. Same shape as the GCP one. |
| `azure-create-install-config` | Writes an Azure install-config.yaml |
| `azure-destroy-cluster` | Teardown, plus a check that destroy really took everything |
| `gcp-installer-credentials` | One-time: the service account and key `openshift-install` needs |
| `gcp-create-cluster` | Builds a GCP cluster. Same shape as the AWS one, minus the credential dance. |
| `gcp-create-install-config` | Writes a GCP install-config.yaml |
| `gcp-destroy-cluster` | Teardown, plus a check that destroy really took everything |

Everything that touches the cloud takes `--dry-run`, and nothing
prompts. These are meant to be free-range: they do what you asked
without stopping to check, and `--dry-run` is how you rehearse. A
prompt is only a guard if you know something the script does not, and
here the script knows more -- it has already checked for name
collisions and existing resources.

## Three masters, not one

`aws-create-install-config` defaults `controlPlane.replicas` to 3. One
master looks like an easy saving and is not.

With a single control-plane node, every kube-apiserver revision takes
the entire API down until it completes, so ordinary operator rollouts
present as outages. Worse is the bootstrap window: while the bootstrap
node is still a member, etcd has two members, and a majority of two is
two. Lose either and you lose quorum, and the etcd operator cannot
remove a dead member without quorum to do it with. That is a deadlock
that ends the cluster rather than degrading it.

Three masters costs two extra m6i.xlarge and removes both. Set
`CONTROL_PLANE_REPLICAS=1` if you want the cheap one anyway; the script
warns and proceeds.

Note that `openshift-install` does not let you change this afterwards.
It is an install-time decision, so getting it wrong means rebuilding.

## Building a cluster

The whole sequence, from a machine that has never done this:

```
aws-install-saml                        # once per machine

kinit <you>@IPA.REDHAT.COM              # VPN up; whenever the ticket expires
aws-login --force                       # every hour, see below

# About 45 minutes. PULL_SECRET and SSH_KEY have defaults, but name them
# anyway: they are the two inputs that come from outside this repo, and an
# invocation that spells them out documents itself for whoever runs it
# next on a machine laid out differently from yours.
PULL_SECRET=$HOME/.secrets/pull-secret.json \
SSH_KEY=$HOME/.ssh/id_ed25519.pub \
  aws-create-cluster
```

That is genuinely all of it. `aws-create-cluster` fetches
`openshift-install`, extracts and patches `ccoctl`, writes an
install-config, runs the credential dance and installs the cluster.

The pull secret is the one from console.redhat.com, needing `quay.io` and
`registry.redhat.io` at minimum. To pull CI payloads as well, merge in
`registry.ci.openshift.org` with `oc registry login --to $PULL_SECRET`.

Rehearse first if you like. The dry run generates a throwaway config
(or reads your `INSTALL_CONFIG`) and runs every precondition against
it, so it exercises the same checks a real run does rather than a
subset:

```
PULL_SECRET=$HOME/.secrets/pull-secret.json \
SSH_KEY=$HOME/.ssh/id_ed25519.pub \
  aws-create-cluster --dry-run
```

### Inputs

Nothing is required. Every input has a default, and the defaults are
the answer you almost always want.

| Variable | Default | Why you would change it |
|:---|:---|:---|
| `CLUSTER_USER` | `$USER` | Your local account name is not the name you want in AWS |
| `CLUSTER` | `clusters/aws-<short>-<ocp>` | Build somewhere other than inside the repo |
| `AWS_PROFILE` | `saml` | Another profile holds the credentials |
| `PULL_SECRET` | `~/.secrets/pull-secret.json` | Yours lives elsewhere |
| `SSH_KEY` | `~/.ssh/id_ed25519.pub` | A different key should reach the nodes |
| `BASE_DOMAIN` | `qe.devcluster.openshift.com` | A different Route53 zone |
| `AWS_REGION` | `us-east-2` | Another region. Check Route Server is available there first |
| `CONTROL_PLANE_REPLICAS` | `3` | You want the cheap, fragile one. See below |
| `WORKER_REPLICAS` | `3` | Fewer workers |
| `CONTROL_PLANE_TYPE`, `WORKER_TYPE` | `m6i.xlarge` | Bigger nodes; `m6i.metal` for virt |
| `OCP_CHANNEL` | `stable-4.22` | A different release stream |
| `OPENSHIFT_INSTALL` | `<cluster>/bin/openshift-install` | Reuse a binary you already have |
| `CCOCTL` | `<cluster>/bin/ccoctl` | As above |
| `INSTALL_CONFIG` | generate one | You have a topology you want. The copy's `metadata.name` is rewritten to the generated cluster name; everything else is yours |

There is no positional argument. The name is always
`<user>-<YYMMDDHHMM>`, so today you get something like `<user>-2608061003`.
Retrying means running it again, which produces a new name and a new
directory, so nothing from a failed attempt can leak into the next one.

### Naming

`<user>-<short>`, and the short part carries the time as well as the
date because the OIDC bucket name has to be globally unique. A date
alone collides with itself the second time you build a cluster in a
day, which is exactly what testing this requires.

### What it actually does

1. **Preflight.** Every precondition, reported together, before
   anything exists. Commands on PATH, credentials working, pull secret
   readable, config parses, `metadata.name` valid per RFC 1123,
   `credentialsMode: Manual`, a Route53 zone for the base domain, the
   OIDC bucket name free, no IAM roles already using the cluster name,
   three control-plane nodes, and whether your session outlives the
   install.
2. **`openshift-install`** into the cluster's own `bin/`.
3. **`ccoctl`** extracted from that exact payload, and patchelf'd,
   because the payload binary will not execute on NixOS.
4. **install-config**, with a copy kept aside: `create manifests`
   consumes the original and step 6 needs it.
5. **`create manifests`**.
6. **Credential requests**, with `--included`. Not optional. See below.
7. **`ccoctl aws create-all`**: IAM roles, OIDC provider, S3 bucket.
8. **Merge** the STS manifests and `tls/` into the install directory.
9. **`create cluster`**.

A failed run is not resumed. Rerunning produces a fresh name and a
fresh directory, so nothing from the failed attempt can leak into the
next one, and the failure output says what now exists in AWS and how
to remove it (`aws-destroy-cluster` copes even when the install died
before a cluster existed). The exception is an expired session during
step 9: the cluster is fine, only the installer stopped waiting, and
`wait-for install-complete` picks it up. See below.

### Why `--included` is not optional

`oc adm release extract --credentials-requests` without it hands you a
request for every optional capability in the payload. `ccoctl` turns
each into a manifest. Any manifest naming a namespace your cluster will
never create wedges the install completely: `cluster-bootstrap` retries
it forever, never writes `kube-system/bootstrap`, and bootstrapping
times out at 45 minutes with a control plane that is otherwise
perfectly healthy.

ClusterAPI is the one that catches you on a default AWS install. It is
not in the default capability set, so `openshift-cluster-api` never
exists, so `capa-manager-bootstrap-credentials` can never be created.
`--included` reads your install-config and filters the requests to the
capabilities you actually enabled.

Necessary, but not sufficient. Measured on 4.22.8, `--included` still
emits the cluster-api request: it is gated by a feature gate but
annotated with a capability, so the capability filter keeps it. The
script therefore also drops any request carrying a feature-gate
annotation, parking it in `credreqs-dropped/` rather than deleting it.
If a gate is ever promoted into the default set and a component later
degrades for want of a credential, its request is sitting there: move
it back into `credreqs/` and run `ccoctl aws create-all` in the
cluster directory by hand.

The symptom is indistinguishable from a broken control plane, which is
why it is worth knowing in advance.

### Sessions are shorter than installs

The role that can create an OIDC provider caps sessions at 3600
seconds. An install takes 35 to 45 minutes and `openshift-install`
holds one set of static credentials for the whole run without
refreshing them. So mint immediately before building, not half an hour
earlier. Preflight warns when your role caps below 90 minutes.

If it does expire mid-install, nothing is lost. Mint again and resume:

```
aws-login --force
<cluster>/bin/openshift-install wait-for install-complete --dir=<cluster>
```

## Cluster directories

One directory per cluster, under `clusters/`, and it owns everything.
The name is `<cloud>-<YYMMDDHHMM>-<version>`, because `clusters/`
holds both clouds and the prefix is how you tell which teardown
script a directory wants. Nothing reads it, though: the destroy
scripts decide the cloud from `cluster-facts` and `metadata.json`, so
directories made before the prefix existed keep working.

```
clusters/aws-2608061003-4228/  the suffix is the OCP version, 4.22.8
  bin/openshift-install        the exact binary that built it
  bin/ccoctl                   from the same payload, patched
  install-config.yaml.bak      the config, with your pull secret inlined
  manifests/  openshift/       rendered assets
  credreqs/                    what --included selected
  credreqs-dropped/            feature-gated requests, parked not deleted
  ccoctl-output/               IAM, OIDC and the signing key
  auth/kubeconfig              how you talk to it
  auth/kubeadmin-password
  metadata.json                clusterName, infraID, region
  cluster-facts                the same identifiers, surviving destroy
  .envrc                       cd in and oc points here
  .openshift_install.log
```

That costs about 840MB per cluster and buys a guarantee: a cluster can
always be torn down using the binaries that built it, whatever later
installs have done to the repo. `clusters/` is gitignored, and so is
everything else not explicitly allowed.

Directories are not cleaned up. Yesterday's cluster is still worth
reading after it stops existing, and a teardown tool that erases the
evidence is one you cannot use to find out what went wrong. Delete them
yourself when you are finished.

## Route servers

The operator discovers route servers and endpoints; it never creates
them. Until the rosa-bgp Terraform exists, these fill the gap:

```
export KUBECONFIG=clusters/aws-<dir>/auth/kubeconfig
export AWS_PROFILE=saml

aws-create-route-servers --dry-run
aws-create-route-servers          # prints the CUDNBgpConfig snippet
aws-list-route-servers            # account-wide, flags orphans
aws-delete-route-servers
```

`aws-create-route-servers` reads the infra id and region from the
cluster your KUBECONFIG points at, then makes one route server plus one
endpoint per availability zone and associates it with the cluster's
VPC. Rerunning adopts what already exists rather than creating a second
set, so it doubles as a check on the current state.

Two things worth knowing:

- The Amazon-side ASN (`ASN`, default 65000) must differ from the
  `localASN` in your CUDNBgpConfig, or the session is not eBGP. The
  script warns when another route server in the region already uses
  your ASN, which only matters if the VPCs are ever peered.
- Endpoints bill hourly and belong to the VPC, not the cluster, so the
  QE reaper never removes them. `aws-destroy-cluster` deletes them as
  its first phase; `aws-delete-route-servers` on its own is for when
  the route servers go but the cluster stays, and once the cluster is
  gone it still works if you name things:
  `INFRA=<infra-id> AWS_REGION=<region> aws-delete-route-servers`.

## Teardown, and why it needs a script

A cluster leaves resources keyed on two different identifiers:

- **infra id** (`<name>-7sqbd`) for the cluster and its route servers
- **cluster name** (`<name>`) for the IAM roles, OIDC provider and S3
  bucket that `ccoctl` created before the installer ever ran

`openshift-install destroy cluster` only knows the infra id. It never
learns about the `ccoctl` resources, so they survive teardown. They are
free, but the S3 bucket name stays taken, so rebuilding under the same
cluster name collides.

Both identifiers live in `metadata.json`, which destroy deletes on
success -- and which does not exist at all if the install died before
`create cluster` ran. So `aws-create-cluster` records them in a
`cluster-facts` file before anything is created, and destroy reads
that first, falling back to `metadata.json`. A facts file with no
infra id means the install never got as far as a cluster, and destroy
then skips straight to the ccoctl residue, which is the case where
cleanup matters most:

```
export CLUSTER=clusters/aws-2608061003-4228

aws-destroy-cluster --dry-run
aws-destroy-cluster
```

Route servers go first, because their endpoints sit in the subnets the
installer wants to delete. `openshift-install` and `ccoctl` are found in
the cluster's own `bin/`.

This deletes cloud resources and nothing else. For a broader sweep when
`destroy` exits early and you suspect something is still billing, use
`aws_cleanup.sh` from the aws-sso-cluster repo: it probes NAT gateways,
load balancers, EBS volumes, VPCs, Elastic IPs and network interfaces,
which this does not yet.

## Credentials that outlive the install

`cmd/aws-credential-process` exists because a cluster install takes 35
to 45 minutes and the role that can run `ccoctl` caps sessions at an
hour. Every install is a race.

`openshift-install` holds one set of static credentials for the whole
run. The AWS SDK will refresh credentials by itself, but only if they
arrive through `credential_process` with an `Expiration` attached, and
`aws-saml.py` writes neither. So this runs `aws-saml.py`, reads back the
profile it wrote, and emits it as JSON with an expiry.

Build it once, then point a profile at the binary:

```
go build -o ~/.local/bin/aws-credential-process ./cmd/aws-credential-process
```

```
[profile saml-refresh]
region = us-east-2
credential_process = /home/you/.local/bin/aws-credential-process
```

Two things about that stanza. The profile name must differ from the one
`aws-saml.py` writes into, or the static credentials win. And the path
has to be absolute: `credential_process` does not expand `~`, and a
tilde fails with `No such file or directory` quoting the literal path,
which reads like a missing binary rather than a quoting problem.

Use it by exporting `AWS_PROFILE=saml-refresh` instead of `saml`.
Nothing else changes.

It caches. The SDK invokes `credential_process` per client, so without a
cache every `aws` call would re-run `aws-saml.py` and hit Kerberos.
Credentials are persisted with their expiry under
`${XDG_CACHE_HOME}/aws-credential-process` and only re-minted within ten
minutes of expiring.

### What it was measured doing

Verified 2026-08-10 against the QE account with the restricted role.

From a cold cache and a session that had genuinely expired -- the
static profile was returning `InvalidClientTokenId` -- a call through
`saml-refresh` returned a valid identity in under three seconds and
wrote a cache entry carrying an `Expiration` an hour out. A second call
returned the same identity without touching the cache file, so
`aws-saml.py` did not run and Kerberos was not hit. With the cached
expiry rewritten to five minutes out, inside the ten-minute refresh
window, the next call re-minted and recorded a fresh hour.

That establishes the provider refreshes. It does not by itself prove
`openshift-install` picks a refresh up mid-run: that is how the SDK is
documented to behave with a `credential_process` provider, and the
proof would be an install that outlives its first session.

One assumption is worth knowing. The `Expiration` is computed locally
as invocation time plus the requested duration, not read back from AWS.
That is exact while the role caps at the 3600 seconds we ask for, but
if a role ever granted less than requested, the recorded expiry would
be optimistic and the refresh would fire too late.

## GCP

The same shape, minus the credential dance. The AWS account's
restricted role forces `credentialsMode: Manual`, and Manual is what
drags in ccoctl, credential-request extraction, the feature-gate
filter and manifest merging. The GCP project grants Owner, so the
installer's default mint mode holds: the cloud credential operator
creates per-component service accounts itself, keyed on the infra id,
and deletes them again on destroy. `gcp-create-cluster` is
`aws-create-cluster` with that whole middle removed.

One-time setup. The installer wants a service-account key, not your
gcloud login, because mint mode embeds the credential in the cluster:

```
gcloud auth login                  # your own login, for the preflight queries
export GCP_PROJECT=<project-id>    # .envrc.local, like the AWS account id
gcp-installer-credentials          # service account + key, idempotent
```

Then the same rhythm as AWS:

```
PULL_SECRET=$HOME/.secrets/pull-secret.json \
SSH_KEY=$HOME/.ssh/id_ed25519.pub \
  gcp-create-cluster --dry-run

PULL_SECRET=$HOME/.secrets/pull-secret.json \
SSH_KEY=$HOME/.ssh/id_ed25519.pub \
  gcp-create-cluster

CLUSTER=clusters/gcp-<dir> gcp-destroy-cluster
```

Differences worth knowing, next to AWS:

- No session race. Service-account keys do not expire, so there is no
  mint-immediately-before-building ritual and no resume dance. Your
  gcloud login token can still go stale (`invalid_grant`); that only
  affects the preflight queries, and `gcloud auth login` renews it.
- `GCP_BASE_DOMAIN` is discovered from the project's only public Cloud DNS
  zone rather than baked in. If the project grows a second zone, set
  it yourself; the error lists the candidates.
- An install that dies before `create cluster` leaves nothing in GCP
  at all. Mint mode creates nothing up front, so there is no ccoctl
  residue and no OIDC-bucket collision to preflight for. The analogous
  check is DNS records for `api.<name>.<domain>` and leftover service
  accounts named for the cluster.
- No route servers yet. The GCP analogue is Cloud Router, and that
  side arrives with the bgp-cloud-connector work;
  [rh-mobb/osd-gcp-cudn-routing](https://github.com/rh-mobb/osd-gcp-cudn-routing)
  is the prototype to mine.

## Azure

The same shape again, and for the same reason as GCP: no ccoctl. Azure
has no mint mode at all -- `openshift-install explain
installconfig.credentialsMode` lists Passthrough and Manual for Azure
and nothing else -- so the config carries no `credentialsMode` line,
the cloud credential operator copies the one service principal into
each component, and nothing is created before the installer runs.

What Azure adds instead is that the credential may not be yours to
make. `openshift-install` reads a service principal from
`~/.azure/osServicePrincipal.json` (`AZURE_AUTH_LOCATION` moves it),
and there is no path that authenticates as your `az login`. Two roles
on the subscription are needed and neither is optional: Contributor to
build the cluster, and User Access Administrator because the installer
creates a user-assigned managed identity and assigns it a role, which
Contributor explicitly cannot -- `Microsoft.Authorization/*/Write` is
in its `notActions`.

Registering an application and granting it those roles are separate
permissions, and a tenant may well give you the first without the
second. An application with no roles is an orphan rather than a
credential, so `azure-installer-credentials` tests for the second
before it creates anything, and refuses with the two `az role
assignment create` lines to take to whoever owns the subscription.
Given the client id and secret of a principal that already holds them,
write the four fields into the file yourself and skip that script
entirely.

With the file in place it is the same rhythm as the other two:

```
az login                           # your own login, for the preflight queries

PULL_SECRET=$HOME/.secrets/pull-secret.json \
SSH_KEY=$HOME/.ssh/id_ed25519.pub \
  azure-create-cluster --dry-run

PULL_SECRET=$HOME/.secrets/pull-secret.json \
SSH_KEY=$HOME/.ssh/id_ed25519.pub \
  azure-create-cluster

CLUSTER=clusters/azure-<dir> azure-destroy-cluster
```

Differences worth knowing, next to GCP:

- Your `az login` and the credentials file can name different
  subscriptions, and nothing warns you: the installer uses the file
  and every preflight query uses the login, so a preflight can vouch
  for a subscription the cluster was never going to be built in. They
  are compared, and a disagreement stops the run before anything
  exists.
- `AZURE_BASE_DOMAIN` is a constant where GCP discovers its zone. A
  shared subscription accumulates delegated zones by the dozen and
  discovery would have nothing to choose between them. The resource
  group holding it is discovered, because that lookup has one answer.
- A cluster is one resource group, `<infra-id>-rg`, plus two record
  sets in the base domain's zone. Destroy takes all of it, so there is
  no residue phase -- only the audit afterwards, which is what
  actually looks.
- Cluster names must begin with a lower-case letter here and on GCP,
  not merely be RFC 1123. A `CLUSTER_USER` starting with a digit
  passes every other check and is rejected by the installer.
- Do not read a full record-set listing into a shell variable. A zone
  shared by a fleet holds thousands of them, and a few thousand names
  is comfortably past the 128KB a single environment string may hold:
  every `exec` after that assignment dies with `Argument list too
  long`, starting with the `grep` meant to read it. Filter in
  `--query` instead, where `az` does the matching in Python and hands
  back two lines.
- No route servers yet. The Azure analogue is Azure Route Server, and
  that side arrives with the bgp-cloud-connector work, as on GCP.

## Why bash, mostly

These scripts sequence `aws`, `oc`, `ccoctl` and `openshift-install`.
Rewriting that in Go buys wrappers around four binaries whose failure
modes you inherit either way, plus a build step. So: bash, until a piece
genuinely wants to be a program. `aws-credential-process` earned it
because it parses INI, emits JSON, does clock arithmetic and manages a
cache, all of which bash does badly.

On error handling, `set -euo pipefail` stays as a backstop for the
command nobody remembered to check. It is not the mechanism. Anything
whose failure has actually been thought about goes through `try`,
`phase` or `wait_until`, all of which return rather than exit, so the
caller decides. Teardown depends on this: stopping at the first error is
how orphaned resources happen.

`wait_until` takes a predicate as a command, which is how the polling
loops it replaced should always have worked. Those loops fell out
silently when they exhausted, and the script carried on as though the
wait had succeeded.
