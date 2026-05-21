# 02 — Secret dep

A small cluster with **one real inter-service dependency**: a web service
that reads database credentials from a Kix-managed Secret.

**You'll learn:** how Kix wires deps between instances using
`deps.<arg> = ref.<ns>.<inst>`, what that produces in the rendered K8s
manifests, and how a rename breaks compile.

## Instances

| Name | Package | Role |
|---|---|---|
| `db-credentials` | `secret` | Kubernetes Secret with fake DB creds |
| `web` | `secret-echo` | nginx pod that reflects the creds over HTTP |
| `ping` | `echo-server` | stand-alone, no deps |

The interesting line is in `web`:

```nix
deps.credentials = ref.example-02.db-credentials;
```

That tells Kix which instance fulfils the `secret-echo` package's
`credentials` build arg. Kix then wires the Secret's keys
(`username`/`password`/`host`/`port`) into the pod's env vars and adds
a `kix.dev/depends-on` annotation to the Deployment so the deploy DAG
knows the order.

## Run

From the repo root (kind cluster assumed already up — see the top-level
[README](../../README.md) if not):

```sh
kix deploy 02-secret-dep -y
kix pf 02-secret-dep web 8080:80    # blocks; Ctrl-C to stop
```

Then in another terminal:

```sh
curl http://localhost:8080/
# DB_USERNAME=demo_user
# DB_PASSWORD=supersecret-not-really
# DB_HOST=demo-db.example-02.svc.cluster.local
# DB_PORT=5432
```

The `secret-echo` pod literally wouldn't have those env vars in its
environment if Kix hadn't wired the Secret in — they don't appear
anywhere in this folder, only in `kix/packages/secret-echo/default.nix`
upstream.

## Things to try

- **See the wiring:** `kix build 02-secret-dep` prints the YAML; look
  for `secretKeyRef` and the `kix.dev/depends-on` annotation on the
  web Deployment.
- **Break the dep:** change `ref.example-02.db-credentials` to a name
  that doesn't exist (e.g. `ref.example-02.postgres`) and re-run
  `kix deploy 02-secret-dep -y`. `kix` refuses with an "unknown
  instance" error.
- **Try implicit DI:** drop the `deps.credentials = ...` line entirely.
  Kix still wires the dep because `db-credentials` has
  `aliases = [ "credentials" ]`. Cleaner at scale, less explicit for
  newcomers.
- **Inspect the dep graph:** `kix inspect 02-secret-dep`.
- **Forward `ping` too:** `kix pf 02-secret-dep ping 8081:80`, then
  `curl http://localhost:8081/`.
