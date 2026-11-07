#!/usr/bin/env python3
"""Check docs/claude-sandbox-guide.html against the code it documents.

- Every launcher flag used in the guide's commands (and its command builder)
  must be accepted by the matching launcher script.
- The Claude built-in sandbox settings shown for macOS must be exactly the JSON
  the macOS test suite validates with `claude doctor`.
"""
import html, json, re, sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
guide = (root / "docs/claude-sandbox-guide.html").read_text()
errors = []

def launcher_flags(path):
    src = (root / path).read_text()
    flags = set()
    for m in re.finditer(r"^\s+((?:-[-\w]+\|?)+)\)", src, re.M):
        flags.update(f for f in m.group(1).split("|") if f)
    return flags

linux = launcher_flags("claude-sandbox.sh")
mac = launcher_flags("macos/claude-mac-sandbox.sh")
# Flags the guide passes through to claude itself (documented Claude Code CLI flags).
claude_flags = {"--continue", "--resume", "--fork-session", "-n", "--name", "--version"}
print(f"linux launcher flags: {sorted(linux)}")
print(f"mac launcher flags:   {sorted(mac)}")

def code_snippets():
    """Text of every <pre>/<code> block, plus command strings in the scenario panel."""
    body = guide[: guide.index("<script>")]
    for m in re.finditer(r"<(pre|code)[^>]*>(.*?)</\1>", body, re.S):
        yield html.unescape(re.sub(r"<[^>]+>", "", m.group(2)))
    js = guide[guide.index("<script>"):]
    for m in re.finditer(r"C\((['\"])(.*?)(?<!\\)\1\)", js, re.S):
        yield m.group(2).replace("\\n", "\n").replace("\\'", "'")

NAME = re.compile(r"(?<![\w-])(claude-mac-sandbox|claude-sandbox)(?![\w-])")
seen = 0
for snippet in code_snippets():
    for line in snippet.splitlines():
        line = line.split("#", 1)[0]
        for m in NAME.finditer(line):
            if re.search(r"-t\s+$", line[: m.start()]):
                continue                      # an image tag, not the launcher
            name = m.group(1)
            allowed = (mac if name == "claude-mac-sandbox" else linux) | claude_flags
            if name == "claude-mac-sandbox":
                allowed |= {"-p"}             # macOS launcher passes -p straight to claude
            toks = re.split(r"\s+", line[m.end():].split("'", 1)[0].strip())
            for t in toks:
                if t in ("--", "--shell", "&&", "|", ";"):
                    break                     # the rest belongs to claude, bash or the shell
                t = t.rstrip(".,")
                if t.startswith("-") and t not in allowed:
                    errors.append(f"{name}: unknown flag {t!r} in: {line.strip()}")
            seen += 1

# Command builder: flags pushed in the script, checked per platform branch.
js = guide[guide.index("<script>"):]
for flag in set(re.findall(r'a\.push\("(-[-\w]+)"', js)):
    if flag not in linux | mac | claude_flags:
        errors.append(f"command builder emits unknown flag {flag!r}")
for flag in ["--no-keychain", "--allow-git-config"]:
    if flag in js and flag not in mac:
        errors.append(f"command builder emits {flag} but macOS launcher lacks it")
for flag in ["--gitconfig", "--allow", "--net", "--auth", "--ro", "--yolo", "--shell"]:
    if flag in js and flag not in linux:
        errors.append(f"command builder emits {flag} but Linux launcher lacks it")

# Built-in sandbox settings snippet == tested JSON
m = re.search(r'<pre>(\{\s*"sandbox".*?)</pre>', guide, re.S)
t = re.search(r"cat > \"\$BASE/builtin-cfg/settings.json\" <<'JSON'\n(.*?)\nJSON", (root / "tests/macos/run-tests.sh").read_text(), re.S)
if not m or not t:
    errors.append("could not find the built-in sandbox settings in the guide or the macOS tests")
elif json.loads(html.unescape(m.group(1))) != json.loads(t.group(1)):
    errors.append("built-in sandbox settings in the guide differ from the JSON tested in tests/macos/run-tests.sh")

print(f"checked {seen} launcher commands in the guide")
if errors:
    for e in errors:
        print("ERROR:", e)
        print(f"::error title=guide out of sync::{e}")
    sys.exit(1)
print("guide matches the launchers and tested settings")
