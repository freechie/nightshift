#!/bin/bash
# Prove a test-mode purchase without touching the real license file.
# With no STRIPE_SECRET_KEY, exit 2. A real key prints one Checkout URL
# for a fresh install id. The caller completes payment in the browser.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
real="$HOME/Library/Application Support/nightshift/license"

stamp() {
  if [[ -e "$1" ]]; then
    stat -f %m "$1"
  else
    echo missing
  fi
}

before="$(stamp "$real")"
fail() {
  echo "$*" >&2
  after="$(stamp "$real")"
  if [[ "$before" != "$after" ]]; then
    echo "real license mtime changed" >&2
    exit 1
  fi
  exit 2
}

if [[ -z "${STRIPE_SECRET_KEY:-}" ]]; then
  echo "missing STRIPE_SECRET_KEY" >&2
  after="$(stamp "$real")"
  if [[ "$before" != "$after" ]]; then
    echo "real license mtime changed" >&2
    exit 1
  fi
  exit 2
fi

tmp="$(mktemp -d /tmp/nsv.XXXX)"
store="$(mktemp -d /tmp/nsstore.XXXX)"
cleanup() {
  rm -rf "$tmp" "$store"
}
trap cleanup EXIT

export NIGHTSHIFT_LICENSE_STORE="$store/licenses.json"
export PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-http://127.0.0.1:8787}"
(
  cd "$root/server"
  node setup.js
) || fail "could not set up the test price"

echo "checkout setup wrote a temp store. Complete payment only from a /tmp/nsv home." >&2
after="$(stamp "$real")"
if [[ "$before" != "$after" ]]; then
  echo "real license mtime changed" >&2
  exit 1
fi
exit 0
