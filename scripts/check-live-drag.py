#!/usr/bin/env python3
"""Check the live-drag commit rule against the Swift sources.

Swift has no verifier, and this machine has no Java runtime for TLC. The
state space is the booleans these functions actually branch on, so this
enumerates every one of them. The transitions are read from the source. A
change that makes an already-on drag commit is a failed property. A change
this script can no longer parse is drift, and it does not pass.
"""

from __future__ import annotations

import hashlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLIENT = ROOT / "swift" / "NightShiftClient.swift"
PANEL = ROOT / "swift" / "MenuPanel.swift"
APP = ROOT / "swift" / "App.swift"
NIGHTSHIFT = ROOT / "NightShift.m"

PROPERTY = "AlreadyLiveStaysUncommitted"


class Drift(Exception):
    pass


def extract_func(text: str, signature: str) -> str:
    start = text.find(signature)
    if start < 0:
        raise Drift(f"missing {signature}")
    brace = text.find("{", start)
    if brace < 0:
        raise Drift(f"missing body for {signature}")
    depth = 0
    for index in range(brace, len(text)):
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[start : index + 1]
    raise Drift(f"unclosed {signature}")


def commit_flag(text: str, signature: str) -> str:
    body = extract_func(text, signature)
    yes = "commit:YES" in body
    no = "commit:NO" in body
    if yes == no:
        raise Drift(f"{signature} does not have exactly one commit flag")
    return "commit-yes" if yes else "commit-no"


def live_arm_kind(stage_body: str, preview_flag: str) -> str:
    write_at = stage_body.find("write(warmth)")
    if write_at < 0:
        raise Drift("stage() no longer has an Off arm that calls write(warmth)")
    returned = stage_body.find("return", write_at)
    if returned < 0:
        raise Drift("stage() Off arm no longer returns before the live arm")
    live = stage_body[returned:]
    found = [
        name
        for name in ("previewStrength(", "applyStrength(", "stageStrength(", "write(")
        if name in live
    ]
    if found == ["previewStrength("]:
        return preview_flag
    if not found:
        raise Drift("stage() live arm has no strength write")
    if "previewStrength(" in found and len(found) > 1:
        raise Drift(f"stage() live arm has more than one write: {found}")
    return "commit-yes"


def intent_pair(panel: str) -> tuple[str, str]:
    match = re.search(
        r"onIntent\(slider\.isSettling \? \.(\w+)\(warmth\) : \.(\w+)\(warmth\)\)",
        panel,
    )
    if match is None:
        raise Drift("currentChanged no longer chooses setWarmth or stageWarmth from isSettling")
    return match.group(1), match.group(2)


def intent_kind(name: str, live_kind: str) -> str:
    if name == "stageWarmth":
        return "stage"
    if name == "setWarmth":
        return "commit-yes"
    raise Drift(f"unknown warmth intent {name}")


def require_order(text: str, signature: str, earlier: str, later: str) -> None:
    body = extract_func(text, signature)
    first = body.find(earlier)
    second = body.find(later)
    if first < 0 or second < 0 or first > second:
        raise Drift(f"{signature} no longer does {earlier} before {later}")


def require_call(text: str, signature: str, call: str) -> None:
    body = extract_func(text, signature)
    if call not in body:
        raise Drift(f"{signature} no longer calls {call}")


def stage_result(live_on: bool, enabled: bool, percent: int, live_kind: str) -> tuple[str, bool]:
    """Return the write kind and the liveOn flag after NightShiftClient.stage."""
    if percent >= 1 and not live_on and not enabled:
        # write() calls applyStrength (commit YES) and sets liveOn from percent.
        return "commit-yes", True
    return live_kind, live_on


def check(live_kind: str, tick_intent: str, release_intent: str, preview_intent: str) -> list[str]:
    failures: list[str] = []
    for live_on in (True, False):
        for enabled in (True, False):
            for percent in (40, 0):
                for caller, intent in (
                    ("Color temperature drag tick", tick_intent),
                    ("warmth-key preview", preview_intent),
                ):
                    if intent == "stage":
                        kind, _after = stage_result(live_on, enabled, percent, live_kind)
                    else:
                        kind = intent
                    if live_on and kind != "commit-no":
                        failures.append(
                            "\n".join(
                                [
                                    f"property {PROPERTY} failed",
                                    "Night Shift is already on (liveOn is true).",
                                    f"The pointer or the warmth key is down. The {caller} runs.",
                                    f"The write is {kind}.",
                                    "A committed write waits for release, so the screen does not follow the bead.",
                                    f"State: liveOn={live_on} enabled={enabled} percent={percent}.",
                                ]
                            )
                        )
                release_kind = release_intent if release_intent != "stage" else live_kind
                if release_kind == "stage":
                    release_kind, _after = stage_result(live_on, enabled, percent, live_kind)
                # Release is allowed to commit. Record nothing unless a live caller failed.
                del release_kind
    return failures


def main() -> int:
    client = CLIENT.read_text()
    panel = PANEL.read_text()
    app = APP.read_text()
    nightshift = NIGHTSHIFT.read_text()
    stage = extract_func(client, "func stage(_ warmth: Warmth)")
    write = extract_func(client, "func write(_ warmth: Warmth)")
    current = extract_func(panel, "@objc private func currentChanged")
    mouse_down = extract_func(panel, "override func mouseDown")
    hotkey_preview = extract_func(app, "keys.onPreview = ")
    hotkey_commit = extract_func(app, "keys.onCommit = ")
    require_call(client, "func write(_ warmth: Warmth)", "applyStrength")
    require_order(panel, "override func mouseDown", "releasing = true", "sendAction")
    if "stageWarmth" not in hotkey_preview:
        raise Drift("onPreview no longer calls stageWarmth")
    if "setWarmth" not in hotkey_commit:
        raise Drift("onCommit no longer calls setWarmth")
    settling, tick = intent_pair(current)
    preview_c = extract_func(nightshift, "BOOL previewStrength")
    apply_c = extract_func(nightshift, "BOOL applyStrength")
    preview_flag = commit_flag(nightshift, "BOOL previewStrength")
    if commit_flag(nightshift, "BOOL applyStrength") != "commit-yes":
        raise Drift("applyStrength no longer commits")
    live_kind = live_arm_kind(stage, preview_flag)
    tick_kind = intent_kind(tick, live_kind)
    release_kind = intent_kind(settling, live_kind)
    preview_kind = "stage"
    covered = "\n".join(
        [stage, write, current, mouse_down, hotkey_preview, hotkey_commit, preview_c, apply_c]
    )
    digest = hashlib.sha256(covered.encode()).hexdigest()
    failures = check(live_kind, tick_kind, release_kind, preview_kind)
    if failures:
        print(failures[0])
        print(f"failures: {len(failures)}")
        print(f"sync-hash: {digest}")
        return 1
    # The Off-start tick is a committed write and is outside this property.
    off_kind, off_live = stage_result(False, False, 40, live_kind)
    if off_kind != "commit-yes" or not off_live:
        raise Drift("the Off-start arm no longer matches write()")
    print("live-drag: ok")
    print(f"property: {PROPERTY}")
    print("states: 8 callers: drag-tick, warmth-key preview")
    print(f"sync-hash: {digest}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Drift as error:
        print(f"drift: {error}", file=sys.stderr)
        print("The source no longer matches the check. This is not a pass.", file=sys.stderr)
        sys.exit(2)
