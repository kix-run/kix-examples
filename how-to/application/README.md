# Application package

A small local nginx package used by the application-authoring and basic
operations how-to guides.

The cluster creates two instances from the same package. The package contains
typed options, a generated environment variable, a ConfigMap mount, and an
optional post-deploy health check.

Run the offline checks from the repository root:

```sh
kix check how-to-application
kix build how-to-application
```

Deploy it to the kind cluster used by the examples:

```sh
kix deploy how-to-application -y
```
