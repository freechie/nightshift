#!/bin/bash
# Sign NightshiftSwift.app with a stable identity so its code signature, and any
# macOS grant tied to it, stays the same across rebuilds. Ad-hoc signing ("-")
# changes the signature every time.
# The download zip stays ad-hoc. This script is for the local app you test.
set -euo pipefail

app="${1:?app bundle}"
identity="${NIGHTSHIFT_SIGN_IDENTITY:-}"

if [[ -z "$identity" ]]; then
  identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)"
fi
if [[ -z "$identity" ]]; then
  identity="-"
fi

codesign --force --options runtime --sign "$identity" "$app"

if [[ "$identity" == "-" ]]; then
  echo "dev-sign: ad-hoc signature."
else
  echo "dev-sign: signed with a stable Apple Development identity."
fi
