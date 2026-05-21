# 02-secret-dep — a Kix cluster with one real inter-service dependency.
#
# Three instances in an `example-02` namespace:
#
#   db-credentials  — a Kix-managed Kubernetes Secret holding fake DB
#                     credentials.
#
#   web             — an nginx-based echo service that REQUIRES a
#                     `credentials` dep. The dep is wired below via
#                     `deps.credentials = ref.example-02.db-credentials`.
#                     Kix resolves the reference and injects the secret's
#                     keys (username/password/host/port) into the pod as
#                     env vars. The page reflects them back over HTTP.
#
#   ping            — a stand-alone echo-server with no deps, just to show
#                     a typical multi-instance cluster.
#
# Try renaming `db-credentials` without updating the `ref` below — Kix
# catches it at compile time.
#
# Note on implicit wiring (DI): once `db-credentials` declares
# `aliases = [ "credentials" ]` (already required here — see below), Kix
# can also auto-resolve the dep without the consumer mentioning it at
# all. Drop the `deps.credentials = ...` line and the build still works:
# Kix finds the credentials provider by alias. The implicit form is more
# idiomatic at scale; the explicit form is easier to read in a demo.

{ kix, packages }:

kix.buildCluster {
  name = "02-secret-dep";

  modules = [
    # Sets the kind flavour: kindnet CNI, ephemeral storage, no LoadBalancer.
    kix.flavors.kind

    # `ref` is the cluster fixpoint — `ref.<namespace>.<instance>` is a
    # lazy reference that resolves to that instance's `out` API.
    (
      { ref, ... }:
      {
        namespaces = {
          example-02 = { };
        };

        instances.example-02 = {
          # A Kix-managed Secret with database credentials.
          # The `aliases` line is required by Kix's phase-1 dep pre-pass
          # so it has something to seed the DAG with. The actual wiring
          # below uses an explicit `ref` to make the relationship
          # readable from the consumer site.
          db-credentials = {
            package = packages.secret;
            aliases = [ "credentials" ];
            config = {
              stringData = {
                username = "demo_user";
                password = "supersecret-not-really";
                host = "demo-db.example-02.svc.cluster.local";
                port = "5432";
              };
            };
          };

          # Web service. The `secret-echo` package's `build` function
          # takes a `credentials` arg; the line below tells Kix which
          # instance fulfils it.
          web = {
            package = packages.secret-echo;
            deps.credentials = ref.example-02.db-credentials;
          };

          # Stand-alone echo-server. No dependencies.
          ping = {
            package = packages.echo-server;
            config = {
              message = "pong";
            };
          };
        };
      }
    )
  ];
}
