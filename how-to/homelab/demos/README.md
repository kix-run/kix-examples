# Homelab demo scripts

These scripts create a kind cluster, deploy one of the homelab clusters
with Kix, change it, and check what happened. Each script cleans up its
kind cluster on exit unless you pass `--keep`.

Run them from anywhere. Each script changes to the kix-examples root and
uses the root `flake.nix`, so the cluster names are the ones `kix list
clusters` prints, such as `homelab-kind` and `homelab-kind-tls`.

You need `kind`, `kubectl`, `kix`, `cilium`, `docker` and `python3`. Some
scripts also need `helm` (the Gateway API scripts) or `tmux`, `k9s`,
Google Chrome and `wf-recorder` (`deploy-homelab-kind2.sh`).

## Helpers

| Script | What it does |
|---|---|
| `render-manifests.sh <cluster>` | Renders a cluster with `kix build` into one file per object and prints the directory. The demos diff two of these directories to count the objects a change touches. |
| `kind-local-registry.sh` | Runs a local image registry and points kind nodes at it, so repeat runs do not pull images again. |
| `kind-bake-node-image.sh` | Builds a kind node image with the cluster's images already loaded. |
| `docker-pull-parallel.py` | Pulls a list of images in parallel. The other scripts use it. |

## Deploy a cluster

| Script | Cluster |
|---|---|
| `deploy-homelab-kind.sh` | `homelab-kind`. Runs the Cilium connectivity test, then starts a pod with no labels that must fail to reach the internet. If that pod gets through, the default-deny network policy is broken and the script fails. `--skip-connectivity` and `--skip-netpol-probe` turn these checks off. |
| `deploy-homelab-kind-gateway.sh` | `homelab-kind-gateway`, with Gateway API from the start. |
| `deploy-homelab-kind-tls.sh` | `homelab-kind-tls`, with a self-signed certificate on every Ingress. |
| `deploy-homelab-kind2.sh` | Runs `deploy-homelab-kind.sh` in tmux and records the screen to `recordings/`. |

## Change a running cluster

Each of these deploys `homelab-kind` (or `homelab-kind-env-stamped`),
then deploys a variant with the same cluster name, so Kix treats it as an
upgrade. Most then deploy the baseline again to show the change reverses.

| Script | Variant | What it shows |
|---|---|---|
| `deploy-homelab-kind-gateway-migrate.sh` | `homelab-kind-gateway-migrate` | Moving from ingress-nginx to Gateway API on a running cluster. Kix removes the Ingresses and creates the Gateway and HTTPRoutes in one activation. |
| `rollback-homelab-kind-gateway-migration.sh` | `homelab-kind-gateway-migrate` | `kix rollback` after that migration. The Ingresses and ingress-nginx come back, the HTTPRoutes and Gateway go, and the workloads stay Ready. |
| `demo-upgrade-lane.sh` | `homelab-kind-upgrade-small`, `homelab-kind-upgrade-broad` | A one-line change touches a few objects. Changing `cluster.domain` touches every exposed service. The script then changes a replica count behind Kix's back and shows `kix health` find it and `kix deploy --reconcile` fix it. |
| `demo-tls-migration.sh` | `homelab-kind-tls-migrate` | Adding one ClusterIssuer gives every Ingress TLS, with no change to any service. |
| `demo-pvc-resize.sh` | `homelab-kind-pvc-resize` | Growing application PVCs. |
| `demo-storage-migrate.sh` | `homelab-kind-storage-migrate` | Moving PVCs to a new StorageClass, which replaces the claims. |
| `demo-db-resize.sh` | `homelab-kind-db-resize` | Resizing a volume the StackGres operator owns next to one Kix owns. |
| `demo-pg-version-bump.sh` | `homelab-kind-pg17` | Postgres 16 to 17. The old `postgres-pg16-config` is removed and `postgres-pg17-config` is created. |
| `demo-ns-rename.sh` | `homelab-kind-ns-rename` | Moving File Browser to a new namespace. Kix removes the old objects and creates new ones, so the volume starts empty. |
| `demo-migration-chain.sh` | PVC resize, then StorageClass, then database resize | The three upgrades in a row, then back down the chain to the baseline. |
| `demo-env-stamped.sh` | `homelab-kind-env-stamped-dev-change` | Two environments on one cluster. A change to dev must touch no staging object, or the script fails. |

## Not included

The kixpkgs repository also had a check that builds `homelab-kind`,
then `homelab-kind-gateway-migrate`, then `homelab-kind` again without a
cluster, and checks the first and last outputs are identical. It depends
on kixpkgs scripts, so it is not here. To do the same by hand:

```sh
a=$(./how-to/homelab/demos/render-manifests.sh homelab-kind)
cp -r "$a" /tmp/homelab-kind-first
./how-to/homelab/demos/render-manifests.sh homelab-kind-gateway-migrate
b=$(./how-to/homelab/demos/render-manifests.sh homelab-kind)
diff -r /tmp/homelab-kind-first "$b"
```
