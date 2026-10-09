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

set -u
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
BIN="$ROOT/nightshift"
SUPPORT="$HOME/Library/Application Support/nightshift"
fail=0

stamp() {
  if [ -f "$1" ]; then
    stat -f %m "$1"
  else
    echo missing
  fi
}

before_max=$(stamp "$SUPPORT/max")
before_full=$(stamp "$SUPPORT/full")

reject() {
  name=$1
  want=$2
  shift 2
  out=$(mktemp)
  err=$(mktemp)
  "$BIN" "$@" >"$out" 2>"$err"
  code=$?
  if [ "$code" -ne 1 ]; then
    echo "fail $name: exit $code want 1"
    fail=$((fail + 1))
  fi
  if ! grep -F -q -- "$want" "$err"; then
    echo "fail $name: stderr missing [$want]"
    cat "$err" >&2
    fail=$((fail + 1))
  fi
  if [ -s "$out" ]; then
    echo "fail $name: stdout not empty"
    cat "$out" >&2
    fail=$((fail + 1))
  fi
  rm -f "$out" "$err"
}

help_ok() {
  name=$1
  shift
  out=$(mktemp)
  err=$(mktemp)
  "$BIN" "$@" >"$out" 2>"$err"
  code=$?
  if [ "$code" -ne 0 ]; then
    echo "fail $name: exit $code want 0"
    fail=$((fail + 1))
  fi
  if ! grep -F -q "Menu bar:" "$out"; then
    echo "fail $name: help missing Menu bar"
    fail=$((fail + 1))
  fi
  if [ -s "$err" ]; then
    echo "fail $name: stderr not empty"
    cat "$err" >&2
    fail=$((fail + 1))
  fi
  rm -f "$out" "$err"
}

help_ok "-h" -h
help_ok "--help" --help
help_ok "help" help

reject "101" "usage: nightshift" 101
reject "max" "usage: nightshift" max
reject "max 0" "usage: nightshift" max 0
reject "max 101" "usage: nightshift" max 101
reject "max 60%" "usage: nightshift" max 60%
reject "schedule nope" "use off, custom, or sunset" schedule nope
reject "clock 13" "use 12 or 24" clock 13
reject "login maybe" "use on or off" login maybe
reject "dark maybe" "use on or off" dark maybe
reject "tone maybe" "use on or off" tone maybe
reject "brightness 3" "usage: nightshift" brightness 3

out=$(mktemp)
err=$(mktemp)
"$BIN" ramp '8:30pm;id' >"$out" 2>"$err"
code=$?
if [ "$code" -ne 1 ]; then
  echo "fail ramp inject: exit $code want 1"
  fail=$((fail + 1))
fi
if ! grep -F -q "use a time like 8:30 PM" "$err"; then
  echo "fail ramp inject: stderr"
  cat "$err" >&2
  fail=$((fail + 1))
fi
if grep -F -q "8:30pm;id" "$err" || grep -F -q "8:30pm;id" "$out"; then
  echo "fail ramp inject: echoed payload"
  fail=$((fail + 1))
fi
rm -f "$out" "$err"

after_max=$(stamp "$SUPPORT/max")
after_full=$(stamp "$SUPPORT/full")
if [ "$before_max" != "$after_max" ] || [ "$before_full" != "$after_full" ]; then
  echo "fail files changed: max $before_max -> $after_max full $before_full -> $after_full"
  fail=$((fail + 1))
fi

if [ "$fail" -ne 0 ]; then
  echo "$fail failed"
  exit 1
fi
echo "cli ok"
