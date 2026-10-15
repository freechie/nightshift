#!/bin/sh
# The deployed webhook secret is the dashboard endpoint secret. The stripe
# listen line is only the local http hint. server/.env stays untracked.
set -eu

root=$(git rev-parse --show-toplevel)
setup="$root/server/setup.js"
cd "$root"

if ! git check-ignore -q server/.env; then
  printf 'server webhook: server/.env is not ignored\n' >&2
  exit 1
fi
if git ls-files --error-unmatch server/.env >/dev/null 2>&1; then
  printf 'server webhook: server/.env is tracked\n' >&2
  exit 1
fi

if ! grep -q 'webhookEndpoints.create' "$setup"; then
  printf 'server webhook: setup.js does not create a dashboard endpoint\n' >&2
  exit 1
fi
if ! grep -q 'webhookSecret = endpoint.secret' "$setup"; then
  printf 'server webhook: setup.js does not keep endpoint.secret\n' >&2
  exit 1
fi
if ! grep -q 'localhost:8787/webhook' "$setup"; then
  printf 'server webhook: stripe listen hint does not forward to localhost\n' >&2
  exit 1
fi
count=$(grep -c 'stripe listen' "$setup" || true)
if [ "$count" -ne 1 ]; then
  printf 'server webhook: expected one stripe listen hint, found %s\n' "$count" >&2
  exit 1
fi

# create sits in the https branch. listen sits in the other branch.
awk '
  /if \(base\.startsWith\("https:\/\/"\)\)/ { https = 1; next }
  /if \(!base\.startsWith\("https:\/\/"\)\)/ { https = 0; local = 1; next }
  /webhookEndpoints\.create/ { if (https != 1) bad = "create is outside the https branch" }
  /stripe listen/ { if (local != 1) bad = "stripe listen is outside the local http branch" }
  END {
    if (bad != "") {
      print "server webhook: " bad > "/dev/stderr"
      exit 1
    }
  }
' "$setup"

printf 'server webhook: dashboard secret, local listen hint\n'
