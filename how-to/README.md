# How-to scenarios

Runnable scenarios shared by the Kix how-to guides. Unlike the numbered
tutorials, these are not a sequence. Each directory provides one small cluster
that several related guides can inspect, build, and deploy.

- [`application/`](./application/) covers local package authoring, typed
  options, environment variables, mounts, repeated instances, and post-deploy
  health checks.
- [`homelab/`](./homelab/) is a larger home-server cluster (Immich, File
  Browser, Vaultwarden, StackGres, monitoring, Cilium) for kind, with variants
  that each make one change to it: Gateway API, TLS, volume resizes, a new
  StorageClass, a Postgres upgrade, a namespace move, and two environments on
  one cluster. [`homelab/demos/`](./homelab/demos/) has scripts that deploy
  each change to a kind cluster and check the result.
