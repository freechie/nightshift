#!/bin/sh
# Copyright 2026 John
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
# implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Print a ramp license token for one install. The private key stays in
# ~/.nightshift/license.pem, or in NIGHTSHIFT_LICENSE_KEY.
#   issue-license.sh <install-id> <YYYY-MM-DD>
# Get the install ID by running "nightshift license id" on the Mac being
# licensed. The token works only there, through the end of that UTC day.
# There are no undated or unbound tokens (review finding 6).
# Also record the grant with "node server/admin.js grant <install-id> <day>"
# so the app's refresh, and support moving it with admin.js rebind, see it.
# That prints an install secret once if the install has none; the customer
# enters it with "nightshift license secret" (read from stdin, never argv).

set -eu
key=${NIGHTSHIFT_LICENSE_KEY:-$HOME/.nightshift/license.pem}
if [ $# -ne 2 ]; then
  echo "usage: issue-license.sh <install-id> <YYYY-MM-DD>" >&2
  exit 1
fi
install=$(printf '%s' "$1" | tr 'A-F' 'a-f')
case $install in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
  *)
    echo "use an install ID like 5f0e1c2a-3b4d-4e6f-8a9b-0c1d2e3f4a5b" >&2
    exit 1
    ;;
esac
case $2 in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
  *)
    echo "use a date like 2027-10-01" >&2
    exit 1
    ;;
esac
payload=ramp:$install:$2
file=$(mktemp)
sigfile=$(mktemp)
trap 'rm -f "$file" "$sigfile"' EXIT
printf '%s' "$payload" >"$file"
body=$(openssl base64 -A -in "$file")
if ! openssl pkeyutl -sign -inkey "$key" -rawin -in "$file" -out "$sigfile"; then
  exit 1
fi
sig=$(openssl base64 -A -in "$sigfile")
if [ -z "$sig" ]; then
  echo "could not sign the license" >&2
  exit 1
fi
printf '%s.%s\n' "$body" "$sig"
