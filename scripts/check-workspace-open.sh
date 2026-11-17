#!/bin/sh
# Settings opens URLs only through rampWorkspaceURL, which calls both verdicts.
set -eu

root=$(git rev-parse --show-toplevel)
cd "$root"

# No Objective-C NSWorkspace openURL: left in the tree.
hits=$(git grep -n -I '\[\[NSWorkspace sharedWorkspace\] openURL:' -- '*.m' '*.h' || true)
count=$(printf '%s\n' "$hits" | awk 'NF { n++ } END { print n + 0 }')
if [ "$count" -ne 0 ]; then
  printf 'workspace open: expected 0 ObjC NSWorkspace openURL:, found %s\n' "$count" >&2
  printf '%s\n' "$hits" >&2
  exit 1
fi

# Exactly one Swift NSWorkspace.shared.open, in Settings.openAllowed.
swift_hits=$(git grep -n -I 'NSWorkspace.shared.open' -- '*.swift' || true)
swift_count=$(printf '%s\n' "$swift_hits" | awk 'NF { n++ } END { print n + 0 }')
if [ "$swift_count" -ne 1 ]; then
  printf 'workspace open: expected 1 NSWorkspace.shared.open, found %s\n' "$swift_count" >&2
  printf '%s\n' "$swift_hits" >&2
  exit 1
fi
printf '%s\n' "$swift_hits" | grep -q '^swift/Settings.swift:.*NSWorkspace.shared.open' || {
  printf 'workspace open: the one NSWorkspace.shared.open is not in Settings.swift\n' >&2
  exit 1
}

awk '
function grab_c(src, name,    line, body, depth, i, c, grabbing) {
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
  opener = ""
  while ((getline line < "swift/Settings.swift") > 0) {
    if (index(line, "func openAllowed") > 0) {
      opener = line
      while ((getline line < "swift/Settings.swift") > 0) {
        opener = opener "\n" line
        if (index(line, "NSWorkspace.shared.open") > 0) break
      }
      break
    }
  }
  close("swift/Settings.swift")
  if (opener == "") fail("openAllowed is missing")
  if (index(opener, "rampWorkspaceURL") == 0) fail("openAllowed does not call rampWorkspaceURL")
  if (index(opener, "NSWorkspace.shared.open") == 0) fail("openAllowed does not open")

  page = grab_c("NightShift.m", "rampWorkspaceURL")
  if (index(page, "nsWorkspaceOpenAllowed(") == 0) {
    fail("rampWorkspaceURL does not call nsWorkspaceOpenAllowed")
  }

  allowed = grab_c("NightshiftLogic.m", "nsWorkspaceOpenAllowed")
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
  if (pages < 4) fail("expected built-in pages in nsWorkspaceOpenAllowed, found " pages)
  print "workspace open: Settings openAllowed → rampWorkspaceURL, both verdicts"
}
'
