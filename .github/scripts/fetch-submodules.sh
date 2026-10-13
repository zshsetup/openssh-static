#!/usr/bin/env bash
# Usage: .github/scripts/fetch-submodules.sh [PATH...]
set -euo pipefail

ATTEMPTS=6
delay=15

# savannah.gnu.org intermittently returns HTTP 500, so retry with exponential backoff and jitter.
for attempt in $(seq "$ATTEMPTS"); do
  if git submodule update --init --depth 1 --recursive -- "$@"; then
    exit 0
  fi
  [ "$attempt" = "$ATTEMPTS" ] && break
  wait=$((delay + RANDOM % delay))
  echo "submodule fetch failed (attempt $attempt/$ATTEMPTS), retrying in ${wait}s" >&2
  sleep "$wait"
  delay=$((delay * 2))
done
echo "submodule fetch failed after $ATTEMPTS attempts" >&2
exit 1
