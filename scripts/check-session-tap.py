#!/usr/bin/env python3
"""Fail unless one file owns the active Session tap.

The mask lives in NightshiftLogic. This script fails the tree when another
file creates an active Session tap, names a key-down event, or checks
Accessibility from a tap callback.
"""

import os
import sys

OWNER = "NightshiftSessionTap.m"
SKIP_DIRS = {".git", "node_modules", "dist", "Nightshift.app"}
FORBIDDEN = ("kCGEventKeyDown", "kCGAnnotatedSessionEventTap")


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


def calls(text, name):
    token = name + "("
    found = []
    start = 0
    while True:
        i = text.find(token, start)
        if i < 0:
            break
        if i > 0 and (text[i - 1].isalnum() or text[i - 1] == "_"):
            start = i + 1
            continue
        depth = 0
        k = i + len(name)
        end = None
        while k < len(text):
            ch = text[k]
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    end = k
                    break
            k += 1
        if end is None:
            break
        found.append((i, text[i + len(name) + 1 : end]))
        start = end + 1
    return found


def split_args(body):
    args = []
    depth = 0
    cur = []
    for ch in body:
        if ch in "([{":
            depth += 1
            cur.append(ch)
        elif ch in ")]}":
            depth -= 1
            cur.append(ch)
        elif ch == "," and depth == 0:
            args.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    tail = "".join(cur).strip()
    if tail or args:
        args.append(tail)
    return args


def ident(arg):
    token = arg.strip()
    if token.startswith("(") and ")" in token:
        token = token[token.rfind(")") + 1 :].strip()
    if token and all(ch.isalnum() or ch == "_" for ch in token):
        return token
    return None


def function_span(text, name):
    needle = name + "("
    start = 0
    while True:
        i = text.find(needle, start)
        if i < 0:
            return None
        if i > 0 and (text[i - 1].isalnum() or text[i - 1] == "_"):
            start = i + 1
            continue
        line_start = text.rfind("\n", 0, i) + 1
        prefix = text[line_start:i]
        if prefix.strip().endswith(";") or "=" in prefix:
            start = i + 1
            continue
        paren = i + len(name)
        depth = 0
        k = paren
        while k < len(text):
            if text[k] == "(":
                depth += 1
            elif text[k] == ")":
                depth -= 1
                if depth == 0:
                    break
            k += 1
        if k >= len(text):
            return None
        rest = text[k + 1 :]
        brace = rest.find("{")
        semi = rest.find(";")
        if brace < 0 or (semi >= 0 and semi < brace):
            start = k + 1
            continue
        body_at = k + 1 + brace
        depth = 0
        p = body_at
        while p < len(text):
            if text[p] == "{":
                depth += 1
            elif text[p] == "}":
                depth -= 1
                if depth == 0:
                    return (i, body_at, p)
            p += 1
        return None


def enclosing_function(text, index):
    best = None
    start = 0
    while True:
        i = text.find("(", start)
        if i < 0 or i > index:
            break
        name_end = i
        name_start = name_end
        while name_start > 0 and (text[name_start - 1].isalnum() or text[name_start - 1] == "_"):
            name_start -= 1
        name = text[name_start:name_end]
        span = function_span(text, name) if name else None
        if span and span[0] <= index <= span[2]:
            if best is None or span[0] > best[0]:
                best = (name, span)
        start = i + 1
    return best


def function_params(text, name):
    span = function_span(text, name)
    if span is None:
        return []
    paren = text.find("(", span[0])
    depth = 0
    k = paren
    while k < len(text):
        if text[k] == "(":
            depth += 1
        elif text[k] == ")":
            depth -= 1
            if depth == 0:
                header = text[paren + 1 : k]
                params = []
                for arg in split_args(header):
                    parts = arg.replace("*", " ").split()
                    if parts and parts[-1] not in {"void"}:
                        params.append(parts[-1])
                return params
        k += 1
    return []


def defined_in(blobs, name):
    found = []
    for path, text in blobs.items():
        if function_span(text, name):
            found.append(path)
    return found


def callback_refs(blobs, text, call_index, arg):
    token = ident(arg)
    if token is None:
        return []
    direct = defined_in(blobs, token)
    if direct:
        return [(path, token) for path in direct]
    owner = enclosing_function(text, call_index)
    if owner is None:
        return []
    fname, _span = owner
    params = function_params(text, fname)
    if token not in params:
        return []
    index = params.index(token)
    refs = []
    for _path, blob in blobs.items():
        for _pos, body in calls(blob, fname):
            args = split_args(body)
            if index >= len(args):
                continue
            called = ident(args[index])
            if called is None:
                continue
            for def_path in defined_in(blobs, called):
                refs.append((def_path, called))
    return refs


def body_of(text, name):
    span = function_span(text, name)
    if span is None:
        return None
    return text[span[1] : span[2] + 1]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    reasons = []
    files = sources(root)
    blobs = {}
    for path in files:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            raw = handle.read()
        blobs[path] = strip_comments_and_strings(raw)

    for path, text in blobs.items():
        rel = os.path.relpath(path, root)
        for symbol in FORBIDDEN:
            start = 0
            while True:
                at = text.find(symbol, start)
                if at < 0:
                    break
                if (at == 0 or not (text[at - 1].isalnum() or text[at - 1] == "_")) and (
                    at + len(symbol) == len(text)
                    or not (text[at + len(symbol)].isalnum() or text[at + len(symbol)] == "_")
                ):
                    reasons.append("%s:%d names %s" % (rel, line_of(text, at), symbol))
                start = at + len(symbol)
        if rel != OWNER:
            at = text.find("kCGSessionEventTap")
            if at >= 0:
                reasons.append("%s:%d names kCGSessionEventTap" % (rel, line_of(text, at)))

    active = []
    callbacks = []
    for path, text in blobs.items():
        rel = os.path.relpath(path, root)
        for pos, body in calls(text, "CGEventTapCreate"):
            args = split_args(body)
            joined = " ".join(args)
            listen = "kCGEventTapOptionListenOnly" in joined
            if not listen:
                active.append((rel, line_of(text, pos), args))
            refs = callback_refs(blobs, text, pos, args[4]) if len(args) >= 5 else []
            if not listen and not refs:
                reasons.append("%s:%d active tap callback is not a named function" % (rel, line_of(text, pos)))
            for def_path, name in refs:
                callbacks.append((def_path, name, not listen))

    if len(active) != 1:
        reasons.append("active Session tap count is %d, want 1" % len(active))
    for rel, line, args in active:
        if rel != OWNER:
            reasons.append("%s:%d creates an active Session tap" % (rel, line))
        joined = " ".join(args)
        if "kCGSessionEventTap" not in joined:
            reasons.append("%s:%d active tap location is not kCGSessionEventTap" % (rel, line))
        if "nsMediaTapMaskBits" not in joined:
            reasons.append("%s:%d Session tap mask is not nsMediaTapMaskBits" % (rel, line))
        if "CGEventMaskBit" in joined:
            reasons.append("%s:%d Session tap builds its own mask" % (rel, line))

    seen = set()
    for def_path, name, session in callbacks:
        rel = os.path.relpath(def_path, root)
        key = (rel, name, session)
        if key in seen:
            continue
        seen.add(key)
        body = body_of(blobs[def_path], name)
        if body is None:
            reasons.append("%s callback %s has no body" % (rel, name))
            continue
        if "AXIsProcessTrusted" in body:
            reasons.append("%s callback %s calls AXIsProcessTrusted" % (rel, name))
        if session and "CGEventTapEnable" in body:
            reasons.append("%s callback %s re-enables its tap" % (rel, name))
        if session and ("NSEventTypeKeyDown" in body or "kCGEventKeyDown" in body):
            reasons.append("%s callback %s reads key-down" % (rel, name))

    for path, text in blobs.items():
        rel = os.path.relpath(path, root)
        body = body_of(text, "brightnessDirection")
        if body and ("NSEventTypeKeyDown" in body or "kCGEventKeyDown" in body):
            reasons.append("%s brightnessDirection reads key-down" % rel)

    if reasons:
        for reason in reasons:
            print(reason)
        return 1
    names = sorted({name for _path, name, _session in callbacks})
    print("session tap ok: " + ", ".join(names))
    return 0


if __name__ == "__main__":
    sys.exit(main())
