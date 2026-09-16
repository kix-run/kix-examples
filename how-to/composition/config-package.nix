# config-package.nix: a small package used by the cluster-composition how-to
# guides.
#
# Recommended reading: 09-typed-options (local packages and typed options).
#
# What's new: package metadata used by package records and policy checks.

{
  scope,
  lib,
  ...
}:

{
  # region:packageMetadataFields
  meta = {
    version = "1.0.0";
    description = "Configuration owned by an application team";
    owner = "platform";
    lifecycle = "stateless";
    scope = "namespace";
  };
  # endregion:packageMetadataFields

  options.message = lib.mkOption {
    type = lib.types.str;
    default = "Hello from Kix";
    description = "Message stored in the generated ConfigMap.";
  };

  build =
    { self, config, ... }:
    {
      configMap = scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = scope.instanceName;
        data.message = config.message;
      };

      root = self.configMap;
    };
}
