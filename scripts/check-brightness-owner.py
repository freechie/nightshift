#!/usr/bin/env python3
"""Fail unless one file owns the DDC queue, the sleeps, and ddcWriteOnce.

The sleep and write counts are the ones already in this tree. A move that
retunes them, or that leaves a second queue or write loop behind, fails.
"""

import os
import sys

OWNER = "NightshiftBrightness.m"
SKIP_DIRS = {".git", "node_modules", "dist", "Nightshift.app"}
LOCKED = (
    "static const useconds_t kDDCAfterWrite = 60000;",
    "static const useconds_t kDDCBetweenReads = 30000;",
    "static const useconds_t kDDCRecheck = 100000;",
    "static const int64_t kDDCSettleDelay = (int64_t)(150 * NSEC_PER_MSEC);",
    "for (int cycle = 0; cycle < 2; cycle++)",
    "for (int attempt = 0; attempt < 4; attempt++)",
    "usleep(10000);",
    "usleep(50000);",
    "usleep(kDDCBetweenReads);",
    "usleep(kDDCRecheck);",
    "slot->retries < 2",
    "nsDDCProbeControl(",
    "nsCombinedLevels(",
    "nsExternalBrightness(kNSDDCProbeSoftware",
    'queue = dispatch_queue_create(\n        "nightshift.ddc"',
)
ONLY_OWNER = (
    "ddcWriteOnce",
    "kDDCAfterWrite",
    "kDDCBetweenReads",
    "kDDCRecheck",
    "kDDCSettleDelay",
    "IOAVServiceWriteI2C",
    "IOAVServiceReadI2C",
)
QUEUE_NAME = "nightshift.ddc"


def sources(root):
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [name for name in dirnames if name not in SKIP_DIRS]
        for name in filenames:
            if name.endswith((".m", ".h")):
                found.append(os.path.join(dirpath, name))
    return found


def blank_keep_newlines(chunk):
    return "".join("\n" if ch == "\n" else " " for ch in chunk)


def strip_comments_and_strings(text):
    out = []
    i = 0
    n = len(text)
    while i < n:
        if text.startswith("//", i):
            j = text.find("\n", i)
            if j < 0:
                out.append(blank_keep_newlines(text[i:]))
                break
            out.append(blank_keep_newlines(text[i:j]))
            i = j
            continue
        if text.startswith("/*", i):
            j = text.find("*/", i + 2)
            if j < 0:
                out.append(blank_keep_newlines(text[i:]))
                break
            out.append(blank_keep_newlines(text[i : j + 2]))
            i = j + 2
            continue
        if text[i] == '"':
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == '"':
                    j += 1
                    break
                j += 1
            out.append(blank_keep_newlines(text[i:j]))
            i = j
            continue
        out.append(text[i])
        i += 1
    return "".join(out)


def line_of(text, index):
    return text.count("\n", 0, index) + 1


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    owner_path = os.path.join(root, OWNER)
    if not os.path.isfile(owner_path):
        print("missing %s" % OWNER)
        return 1
    owner = open(owner_path, encoding="utf-8").read()
    reasons = []
    for snippet in LOCKED:
        count = owner.count(snippet)
        if count != 1:
            reasons.append("%s has %d of %s, want 1" % (OWNER, count, snippet.split("\n")[0]))

    blobs = {}
    for path in sources(root):
        raw = open(path, encoding="utf-8", errors="replace").read()
        blobs[os.path.relpath(path, root)] = strip_comments_and_strings(raw)

    if OWNER not in blobs:
        reasons.append("missing %s" % OWNER)
    else:
        for symbol in ONLY_OWNER:
            for rel, text in blobs.items():
                start = 0
                while True:
                    at = text.find(symbol, start)
                    if at < 0:
                        break
                    before = at == 0 or not (text[at - 1].isalnum() or text[at - 1] == "_")
                    after_at = at + len(symbol)
                    after = after_at == len(text) or not (
                        text[after_at].isalnum() or text[after_at] == "_"
                    )
                    if before and after and rel != OWNER:
                        reasons.append("%s:%d names %s" % (rel, line_of(text, at), symbol))
                    start = at + len(symbol)
            if symbol not in blobs[OWNER]:
                reasons.append("%s does not name %s" % (OWNER, symbol))

    raw = {}
    for path in sources(root):
        raw[os.path.relpath(path, root)] = open(path, encoding="utf-8", errors="replace").read()
    if OWNER not in raw or QUEUE_NAME not in raw[OWNER]:
        reasons.append("%s does not name %s" % (OWNER, QUEUE_NAME))
    for rel, text in raw.items():
        if rel == OWNER:
            continue
        at = text.find(QUEUE_NAME)
        if at >= 0:
            reasons.append("%s:%d names %s" % (rel, text.count("\n", 0, at) + 1, QUEUE_NAME))

    if reasons:
        for reason in reasons:
            print(reason)
        return 1
    print("brightness owner ok: %d locked counts" % len(LOCKED))
    return 0


if __name__ == "__main__":
    sys.exit(main())
