#!/bin/sh
# region:healthCheckScript
set -u

deadline=$(( $(date +%s) + RETRY_FOR ))

while true; do
  if curl --fail --silent --show-error --max-time 10 "$APP_URL" >/dev/null; then
    echo "ok    GET $APP_URL"
    exit 0
  fi

  echo "FAIL  GET $APP_URL"
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "gave up after ${RETRY_FOR}s"
    exit 1
  fi

  sleep 5
done
# endregion:healthCheckScript
