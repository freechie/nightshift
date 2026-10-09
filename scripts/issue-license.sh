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

# Print a ramp license token. The private key stays in
# ~/.nightshift/license.pem, or in NIGHTSHIFT_LICENSE_KEY.
# Pass YYYY-MM-DD to expire at the end of that UTC day.

set -eu
key=${NIGHTSHIFT_LICENSE_KEY:-$HOME/.nightshift/license.pem}
payload=ramp
if [ $# -eq 1 ]; then
  case $1 in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) payload=ramp:$1 ;;
    *)
      echo "use a date like 2027-10-01" >&2
      exit 1
      ;;
  esac
elif [ $# -ne 0 ]; then
  echo "usage: issue-license.sh [YYYY-MM-DD]" >&2
  exit 1
fi
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
