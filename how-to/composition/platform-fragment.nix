# platform-fragment.nix: namespace policy and a platform-owned service.

{ packages }:

{
  # region:platformFragment
  namespaces.apps = {
    labels."platform.example.com/tier" = "application";
    annotations."platform.example.com/owner" = "platform";
  };

  instances.platform.status-api = {
    package = packages.echo-server;
    config.message = "Platform status";
  };
  # endregion:platformFragment
}
