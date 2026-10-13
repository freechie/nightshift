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

# license-server-check, as make package and make install run it.
set -u
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
CHECK="$ROOT/license-server-check"
fail=0
checks=0

# expect MODE VALUE STATUS TEXT: exit STATUS, and TEXT in its output.
expect() {
  checks=$((checks + 1))
  out=$(LICENSE_SERVER="$2" "$CHECK" "$1" 2>&1)
  got=$?
  case "$out" in
    *"$4"*) found=1 ;;
    *) found=0 ;;
  esac
  if [ "$got" != "$3" ] || [ "$found" != 1 ]; then
    echo "license-server-check $1 [$2]: exit $got, want $3 with \"$4\": $out" >&2
    fail=1
  fi
}

expect package "https://license.example.com" 0 "license server: https://license.example.com"
expect package "https://license.example.com:8443/" 0 "license server:"
expect package "" 1 "LICENSE_SERVER is not set"
expect package "HTTPS://License.Example.com:08443/" 1 "its port starts with 0"
expect package "HTTPS://License.Example.com:8443/" 1 "capital letters"
expect package "https://License.example.com" 1 "capital letters"
expect package "Https://license.example.com" 1 "capital letters"
expect package "https://license.example.com:08443" 1 "its port starts with 0"
expect package "https://license.example.com:0" 1 "isn't 1-65535"
expect package "http://license.example.com" 1 "it isn't https"
expect package "http://127.0.0.1:8787" 1 "it isn't https"
expect package "https://license.example.com." 1 "ends in \".\""
expect package "https://user@license.example.com" 1 "a user name"
expect package "https://license.example.com\\@evil.com" 1 "a backslash"
expect package "https://license.example.com/api" 1 "a path"
expect package "license.example.com" 1 "no https://"
expect package "https://x'; touch /tmp/ns-pwned; '" 1 "a space"
expect install "https://license.example.com" 0 "license server: https://license.example.com"
expect install "" 0 "warning: this build has no license server compiled in (LICENSE_SERVER is not set)"
expect install "https://License.example.com" 0 "warning: this build has no license server compiled in (LICENSE_SERVER is not usable: its scheme or host has capital letters"
if [ -e /tmp/ns-pwned ]; then
  echo "license-server-check ran part of LICENSE_SERVER" >&2
  fail=1
fi

if [ "$fail" != 0 ]; then
  exit 1
fi
echo "license-server ok ($checks checks)"
