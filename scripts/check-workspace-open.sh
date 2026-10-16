#!/bin/sh
# One NSWorkspace openURL: in the sources, and it calls both verdicts.
set -eu

root=$(git rev-parse --show-toplevel)
cd "$root"

hits=$(git grep -n -I 'openURL:' -- '*.m' '*.h' || true)
count=$(printf '%s\n' "$hits" | awk 'NF { n++ } END { print n + 0 }')
if [ "$count" -ne 1 ]; then
  printf 'workspace open: expected 1 openURL:, found %s\n' "$count" >&2
  exit 1
fi
printf '%s\n' "$hits" | grep -q '^nightshiftd.m:.*\[\[NSWorkspace sharedWorkspace\] openURL:' || {
  printf 'workspace open: the one openURL: is not an NSWorkspace open in nightshiftd.m\n' >&2
  exit 1
}

awk '
function grab(src, name,    line, body, depth, i, c, grabbing) {
  grabbing = 0
  depth = 0
  body = ""
  while ((getline line < src) > 0) {
    if (!grabbing && line ~ /^[A-Za-z_]/ && index(line, name "(") > 0 && index(line, "{") > 0) {
      grabbing = 1
    }
    if (grabbing) {
      body = body line "\n"
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (c == "{") depth++
        else if (c == "}") depth--
      }
      if (depth == 0) {
        close(src)
        return body
      }
    }
  }
  close(src)
  return ""
}

function fail(msg) {
  print "workspace open: " msg > "/dev/stderr"
  exit 1
}

BEGIN {
  opener = grab("nightshiftd.m", "openWorkspaceURL")
  if (opener == "") fail("openWorkspaceURL is missing")
  n = gsub(/openURL:/, "&", opener)
  if (n != 1) fail("openWorkspaceURL must contain the only openURL:")
  if (index(opener, "rampWorkspaceURL(") == 0) fail("openWorkspaceURL does not call rampWorkspaceURL")

  page = grab("NightShift.m", "rampWorkspaceURL")
  if (index(page, "nsWorkspaceOpenAllowed(") == 0) {
    fail("rampWorkspaceURL does not call nsWorkspaceOpenAllowed")
  }

  allowed = grab("NightshiftLogic.m", "nsWorkspaceOpenAllowed")
  if (allowed == "") fail("nsWorkspaceOpenAllowed is missing")
  purchase = index(allowed, "nsPurchaseURLVerdict(")
  origin = index(allowed, "nsLicenseOriginVerdict(")
  first = index(allowed, "return")
  if (purchase == 0 || origin == 0) fail("nsWorkspaceOpenAllowed does not call both verdicts")
  if (first == 0 || (purchase > first && origin > first)) {
    fail("a verdict is not called before the first return")
  }
  if (index(allowed, "origin == kNSLinkOK) {\n    return false;") == 0) {
    fail("a license origin must not be opened")
  }

  # Built-in pages are the quoted strings in that function.
  rest = allowed
  pages = 0
  while (match(rest, /"[^"]+"/)) {
    literal = substr(rest, RSTART + 1, RLENGTH - 2)
    rest = substr(rest, RSTART + RLENGTH)
    if (index(literal, "://") > 0 || index(literal, "x-apple.") == 1) {
      pages++
      page_url[pages] = literal
    }
  }
  if (pages != 4) fail("expected 4 built-in pages, found " pages)

  daemon = ""
  while ((getline line < "nightshiftd.m") > 0) daemon = daemon line "\n"
  close("nightshiftd.m")
  # Join adjacent Objective-C string literals so a split URL is one string.
  do {
    before = daemon
    while (match(daemon, /@"[^"]*"[[:space:]]*@"[^"]*"/)) {
      chunk = substr(daemon, RSTART, RLENGTH)
      split_at = index(chunk, "\"")
      # chunk is @"AAA" <space> @"BBB"
      sub(/^@"/, "", chunk)
      a = chunk
      sub(/".*/, "", a)
      sub(/.*@"/, "", chunk)
      b = chunk
      sub(/"$/, "", b)
      daemon = substr(before, 1, RSTART - 1) "\"" a b "\"" substr(before, RSTART + RLENGTH)
      before = daemon
    }
  } while (0)

  for (i = 1; i <= pages; i++) {
    if (index(daemon, page_url[i]) == 0) {
      fail("built-in page is not opened from nightshiftd.m: " page_url[i])
    }
  }
  print "workspace open: 1 NSWorkspace openURL:, both verdicts"
}
'
