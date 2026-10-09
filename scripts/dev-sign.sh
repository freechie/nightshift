#!/bin/bash
# Sign Nightshift.app with a stable identity so Accessibility survives rebuilds.
# Ad-hoc signing ("-") changes the signature every time, and macOS drops the grant.
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

codesign --force --sign "$identity" "$app"

if [[ "$identity" == "-" ]]; then
  echo "dev-sign: ad-hoc. Allow Nightshift in Accessibility again after this build."
else
  echo "dev-sign: signed with a stable Apple Development identity."
fi
