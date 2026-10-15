#!/bin/sh
# Match scripts/secret-patterns.txt against a git tree or index.
# Prints file, line, and key name. Does not print the matched line.
#   scan-secrets.sh tree [repo]    tracked work tree (make test)
#   scan-secrets.sh index [repo]   staged files (pre-commit)
#   scan-secrets.sh self-test      fixture with a generated value
set -eu

script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
patterns="$script_dir/secret-patterns.txt"
awk_file="$script_dir/secret-hit.awk"
mode=${1:-tree}
repo=${2:-}

if [ ! -f "$patterns" ] || [ ! -f "$awk_file" ]; then
  printf 'secret scan: %s or %s is missing\n' "$patterns" "$awk_file" >&2
  exit 1
fi

if [ -z "$repo" ]; then
  repo=$(git rev-parse --show-toplevel)
fi

# Print hits on stdout and return 1 when any line matches. Return 0 when
# none match. The matched text stays in a temp file and is removed.
scan_repo() {
  cached=$1
  raw=$(mktemp)
  status=0
  # shellcheck disable=SC2086
  grep -v -e '^#' -e '^$' "$patterns" |
    git -C "$repo" -c color.ui=false grep $cached -I -n -E -f - -- . >"$raw" || status=$?
  if [ "$status" -eq 1 ]; then
    rm -f "$raw"
    return 0
  fi
  if [ "$status" -ne 0 ]; then
    rm -f "$raw"
    printf 'secret scan: git grep failed (%s)\n' "$status" >&2
    return "$status"
  fi
  awk -f "$awk_file" "$raw"
  rm -f "$raw"
  return 1
}

report() {
  cached=$1
  label=$2
  status=0
  hits=$(scan_repo "$cached") || status=$?
  if [ "$status" -eq 1 ]; then
    printf '%s\n' "$label" >&2
    printf '%s\n' "$hits" >&2
    return 1
  fi
  if [ "$status" -ne 0 ]; then
    return "$status"
  fi
  return 0
}

self_test() {
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT INT TERM
  prefix=$(printf 'wh%s' 'sec_')
  body=$(awk 'BEGIN { for (i = 0; i < 24; i++) printf "a" }')
  value="${prefix}${body}"
  git init -q "$tmp"
  printf 'STRIPE_WEBHOOK_SECRET=%s\n' "$value" >"$tmp/leak.env"
  printf 'export "STRIPE_WEBHOOK_SECRET"=%s\n' "$value" >"$tmp/exported.env"
  printf 'see %s in a note\n' "$value" >"$tmp/note.txt"
  git -C "$tmp" add leak.env exported.env note.txt

  assert_hidden() {
    got=$1
    if printf '%s' "$got" | grep -F -q -- "$value"; then
      printf 'secret scan self-test: output included the secret value\n' >&2
      exit 1
    fi
    if printf '%s' "$got" | grep -F -q -- "$body"; then
      printf 'secret scan self-test: output included the secret body\n' >&2
      exit 1
    fi
  }

  assert_names() {
    got=$1
    printf '%s\n' "$got" | grep -F -q '  leak.env:1 (STRIPE_WEBHOOK_SECRET)' || {
      printf 'secret scan self-test: missing leak.env key\n' >&2
      exit 1
    }
    printf '%s\n' "$got" | grep -F -q '  exported.env:1 (STRIPE_WEBHOOK_SECRET)' || {
      printf 'secret scan self-test: missing exported.env key\n' >&2
      exit 1
    }
    printf '%s\n' "$got" | grep -F -q '  note.txt:1' || {
      printf 'secret scan self-test: missing note.txt line\n' >&2
      exit 1
    }
    # The note has no assignment, so it has no key name.
    if printf '%s\n' "$got" | grep -F -q '  note.txt:1 ('; then
      printf 'secret scan self-test: note.txt invented a key\n' >&2
      exit 1
    fi
    return 0
  }

  set +e
  tree_out=$(sh "$script_dir/scan-secrets.sh" tree "$tmp" 2>&1)
  tree_code=$?
  index_out=$(sh "$script_dir/scan-secrets.sh" index "$tmp" 2>&1)
  index_code=$?
  set -e
  assert_hidden "$tree_out"
  assert_hidden "$index_out"
  if [ "$tree_code" -ne 1 ] || [ "$index_code" -ne 1 ]; then
    printf 'secret scan self-test: want exit 1, tree %s index %s\n' "$tree_code" "$index_code" >&2
    exit 1
  fi
  printf '%s\n' "$tree_out" | grep -F -q 'tracked tree holds what looks like a Stripe secret' || {
    printf 'secret scan self-test: tree report missing\n' >&2
    exit 1
  }
  printf '%s\n' "$index_out" | grep -F -q 'pre-commit: staged content holds what looks like a Stripe secret' || {
    printf 'secret scan self-test: index report missing\n' >&2
    exit 1
  }
  assert_names "$tree_out"
  assert_names "$index_out"

  rm -f "$tmp/leak.env" "$tmp/exported.env" "$tmp/note.txt"
  printf 'STRIPE_WEBHOOK_SECRET=\nwhsec_nightshift_test\n' >"$tmp/short.env"
  git -C "$tmp" add -A
  set +e
  clean_out=$(sh "$script_dir/scan-secrets.sh" tree "$tmp" 2>&1)
  clean_code=$?
  set -e
  assert_hidden "$clean_out"
  if [ "$clean_code" -ne 0 ]; then
    printf 'secret scan self-test: short fake should pass, exit %s\n' "$clean_code" >&2
    exit 1
  fi
  printf '%s\n' "$clean_out" | grep -F -q 'secret scan: 0 hits' || {
    printf 'secret scan self-test: clean tree did not report 0 hits\n' >&2
    exit 1
  }
  printf 'secret scan self-test: ok\n'
}

case "$mode" in
  tree)
    if report "" "secret scan: tracked tree holds what looks like a Stripe secret:"; then
      printf 'secret scan: 0 hits\n'
    else
      exit 1
    fi
    ;;
  index)
    report "--cached" "pre-commit: staged content holds what looks like a Stripe secret:" || {
      printf 'Remove it, restage (git add), and rotate the secret if it was ever pushed.\n' >&2
      exit 1
    }
    ;;
  self-test)
    self_test
    ;;
  *)
    printf 'usage: scan-secrets.sh tree|index|self-test [repo]\n' >&2
    exit 1
    ;;
esac
