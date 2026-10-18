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
before_secret=$(stamp "$SUPPORT/install-secret")

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
# Brightness control was removed: these are unknown commands now, refused
# with usage before anything reaches the daemon.
reject "brightness" "usage: nightshift" brightness
reject "brightness 3 40" "usage: nightshift" brightness 3 40
reject "keys" "usage: nightshift" keys
reject "ddc" "usage: nightshift" ddc

# The install secret is read from stdin, never taken as an argument; these
# are refused before anything is read or saved.
value=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
reject "license secret value" "takes no value" license secret "$value"
reject "license secret --replace value" "takes no value" license secret --replace "$value"
reject "license secret value --replace" "takes no value" license secret "$value" --replace
reject "license secret --force" "takes no value" license secret --force
out=$(mktemp)
err=$(mktemp)
"$BIN" license secret "$value" >"$out" 2>"$err" </dev/null
if grep -F -q "$value" "$out" "$err"; then
  echo "fail license secret: echoed the value"
  fail=$((fail + 1))
fi
printf 'not-a-secret\n' | "$BIN" license secret >"$out" 2>"$err"
code=$?
if [ "$code" -ne 1 ] || ! grep -F -q "isn't an install secret" "$err" || grep -F -q "not-a-secret" "$out" "$err"; then
  echo "fail license secret: bad piped secret (exit $code)"
  cat "$err" >&2
  fail=$((fail + 1))
fi
"$BIN" license secret >"$out" 2>"$err" </dev/null
code=$?
if [ "$code" -ne 1 ] || ! grep -F -q "no install secret was entered" "$err"; then
  echo "fail license secret: empty stdin (exit $code)"
  cat "$err" >&2
  fail=$((fail + 1))
fi
rm -f "$out" "$err"

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

# Plain nightshift only reports: with no app reachable it says so and
# starts nothing. A fresh home (CFFIXED_USER_HOME) has no socket.
home=$(mktemp -d)
before_procs=$(pgrep -x nightshiftd | wc -l)
out=$(mktemp)
err=$(mktemp)
CFFIXED_USER_HOME="$home" "$BIN" >"$out" 2>"$err"
code=$?
sleep 1
after_procs=$(pgrep -x nightshiftd | wc -l)
if [ "$code" -ne 1 ] || ! grep -F -q "Nightshift isn't running" "$err" ||
  ! grep -F -q "nightshift <0-100>" "$err" || [ -s "$out" ]; then
  echo "fail status not running: exit $code"
  cat "$err" >&2
  fail=$((fail + 1))
fi
if [ "$before_procs" -ne "$after_procs" ] || [ -e "$home/Library/Application Support/nightshift/nightshiftd.sock" ]; then
  echo "fail status not running: started Nightshift"
  fail=$((fail + 1))
fi
rm -rf "$out" "$err" "$home"

after_max=$(stamp "$SUPPORT/max")
after_full=$(stamp "$SUPPORT/full")
after_secret=$(stamp "$SUPPORT/install-secret")
if [ "$before_max" != "$after_max" ] || [ "$before_full" != "$after_full" ] ||
  [ "$before_secret" != "$after_secret" ]; then
  echo "fail files changed: max $before_max -> $after_max full $before_full -> $after_full secret $before_secret -> $after_secret"
  fail=$((fail + 1))
fi

if [ "$fail" -ne 0 ]; then
  echo "$fail failed"
  exit 1
fi
echo "cli ok"
