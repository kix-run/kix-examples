# custom-resource-package.nix: a small typed custom resource example.
#
# Recommended reading: how-to/application (local package authoring).
#
# What's new: declare how an operator reports readiness for its custom
# resources.

{ scope, ... }:

{
  meta = {
    version = "1.0.0";
    description = "Custom resource readiness example";
    owner = "platform";
  };

  build =
    { self, ... }:
    {
      # region:customResourceReadiness
      widgetCrd = scope.mkCRD (
        scope.crd.fromKind "Widget" { spec.group = "widgets.example.com"; }
        // {
          readiness = {
            path = "/status/phase";
            equals = "Ready";
          };
        }
      );

      widget = self.widgetCrd.out.mkCR scope {
        name = "example";
        spec.size = "small";
      };
      # endregion:customResourceReadiness

      root = self.widget;
    };
}
