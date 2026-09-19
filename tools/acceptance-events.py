#!/usr/bin/env python3
"""Read TUI evidence and restore only the test's exact Codex trust additions."""
import difflib
import json
import os
from pathlib import Path
import sys
import subprocess
import tempfile
import tomllib
from urllib.parse import quote


def records(path):
    with Path(path).open() as stream:
        for line in stream:
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                # A live writer may not have finished its final line yet.
                continue


def event_path(harness, cwd, session, since):
    home = Path.home()
    if harness == "grok":
        path = home / ".grok/sessions" / quote(cwd, safe="") / session / "events.jsonl"
        return path if path.is_file() else None
    if harness == "claude":
        path = home / ".claude/projects" / cwd.replace("/", "-") / (session + ".jsonl")
        return path if path.is_file() else None
    root = Path(os.environ.get("CODEX_HOME", home / ".codex")) / "sessions"
    matches = []
    for path in root.rglob("rollout-*.jsonl"):
        try:
            if path.stat().st_mtime < float(since):
                continue
            for row in records(path):
                if row.get("type") == "session_meta":
                    if row.get("payload", {}).get("cwd") == cwd:
                        matches.append(path)
                    break
        except FileNotFoundError:
            continue
    # Ambiguity is an instrumentation failure, never "take the newest".
    if len(matches) > 1:
        raise ValueError("multiple Codex rollouts match the test cwd")
    return matches[0] if matches else None


def stats(harness, path):
    starts = ends = 0
    last_start = last_end = -1
    for index, row in enumerate(records(path)):
        start = end = False
        if harness == "grok":
            start = row.get("type") == "turn_started"
            end = row.get("type") == "turn_ended"
        elif harness == "codex":
            payload = row.get("payload", {})
            if row.get("type") == "event_msg":
                start = payload.get("type") == "task_started"
                end = payload.get("type") == "task_complete"
        else:
            message = row.get("message", {})
            content = message.get("content", [])
            tool_result = isinstance(content, list) and any(
                isinstance(block, dict) and block.get("type") == "tool_result"
                for block in content
            )
            start = row.get("type") == "user" and not tool_result
            end = row.get("type") == "assistant" and message.get("stop_reason") == "end_turn"
        if start:
            starts += 1
            last_start = index
        if end:
            ends += 1
            last_end = index
    return starts, ends, int(starts > 0 and last_end > last_start)


def restore_trust(backup, config, allowed):
    before = Path(backup).read_bytes()
    target = Path(config)
    after = target.read_bytes() if target.exists() else b""
    if before == after:
        print("trust cleanup: unchanged")
        return
    old_lines = before.decode().splitlines(keepends=True)
    new_lines = after.decode().splitlines(keepends=True)
    additions = []
    for op, _a, _b, c, d in difflib.SequenceMatcher(None, old_lines, new_lines, autojunk=False).get_opcodes():
        if op == "equal":
            continue
        if op != "insert":
            raise ValueError("config changed beyond inserted trust blocks; backup retained")
        additions.append("".join(new_lines[c:d]))
    added = tomllib.loads("".join(additions))
    projects = added.get("projects", {})
    if set(added) != {"projects"} or not projects or not set(projects).issubset(allowed):
        raise ValueError("unexpected config additions; backup retained")
    if any(value != {"trust_level": "trusted"} for value in projects.values()):
        raise ValueError("unexpected trust block contents; backup retained")
    expected = tomllib.loads(before.decode())
    expected_projects = expected.setdefault("projects", {})
    if set(projects).intersection(expected_projects):
        raise ValueError("test would alter existing trust; backup retained")
    expected_projects.update(projects)
    if tomllib.loads(after.decode()) != expected:
        raise ValueError("config diff is not exactly the test's trust blocks")
    # Do not print config values. Preserve bytes and permissions, with one final
    # comparison so a concurrent edit noticed here is left untouched.
    fd, temporary = tempfile.mkstemp(prefix=".pp-trust-", dir=target.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(before)
        os.chmod(temporary, Path(backup).stat().st_mode & 0o777)
        if target.read_bytes() != after:
            raise ValueError("config changed during cleanup; backup retained")
        os.replace(temporary, target)
    finally:
        if Path(temporary).exists():
            subprocess.run(["gio", "trash", temporary], check=True)
    print("trust cleanup: restored exact test additions")


def main():
    operation, *args = sys.argv[1:]
    if operation == "path":
        path = event_path(*args)
        if path is None:
            return 1
        print(path)
    elif operation == "stats":
        print(*stats(*args))
    elif operation == "trust":
        restore_trust(args[0], args[1], set(args[2:]))
    else:
        raise ValueError("unknown evidence operation")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        print(f"acceptance evidence: {error}", file=sys.stderr)
        sys.exit(1)
