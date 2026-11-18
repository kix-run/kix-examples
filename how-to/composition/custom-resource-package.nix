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

      # A Machine stands in for an operator kind such as KubeVirt's
      # VirtualMachine. Its controller writes in status.observedGeneration
      # the generation the running machine started from, so that field stays
      # behind after every edit until the machine restarts.
      machineCrd = scope.mkCRD (
        scope.crd.fromKind "Machine" { spec.group = "machines.example.com"; }
        // {
          # region:customResourceGenerationField
          readiness = {
            path = "/status/printableStatus";
            equals = "Running";
            # The field where the controller reports the generation it has
            # acted on. Kix waits until it reaches metadata.generation.
            observedGeneration = "/status/desiredGeneration";
            # region:customResourcePendingRestart
            # The controller accepted the spec, and the running machine keeps
            # the previous one until someone restarts it.
            pendingRestart = {
              condition = {
                type = "RestartRequired";
                status = "True";
              };
              hint = "Restart the machine to apply the change.";
            };
            # endregion:customResourcePendingRestart
          };
          # endregion:customResourceGenerationField
        }
      );

      running = self.machineCrd.out.mkCR scope {
        name = "running";
        spec.runStrategy = "Always";
      };

      # region:customResourceOwnReadiness
      # This machine should stay stopped, so it replaces the kind's rule.
      # A stopped machine's status.observedGeneration stops advancing, so
      # observedGeneration = false keeps Kix from waiting on it.
      halted = self.machineCrd.out.mkCR scope {
        name = "halted";
        spec.runStrategy = "Halted";
        readiness = {
          path = "/status/printableStatus";
          equals = "Stopped";
          observedGeneration = false;
        };
      };
      # endregion:customResourceOwnReadiness

      root = {
        resource = self.widget;
        requires = [
          self.running
          self.halted
        ];
      };
    };
}
