"""Tab completion: `iso __complete` at each kind of position, its speed, and the zsh and bash scripts
(`iso completion zsh|bash`) loaded in real shells, with zsh's completion builtins stubbed to print what
they're given. No TUI: completion only reads files.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/completion.py"""

import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from iso import REPO, Iso  # noqa: E402

iso = Iso("completion")
iso.env["ISOVIM_PEERS"] = "cleo=cleo.example"
# Shells find this tree's iso first.
iso.env["PATH"] = f"{REPO / 'bin'}:{iso.env['PATH']}"


def complete(*words):
    """(values, descriptions, directive) for the last word."""
    lines = iso.cli("__complete", *words).split("\n")
    assert lines[-1].startswith(":"), lines
    pairs = [line.split("\t", 1) for line in lines[:-1] if line]
    return [p[0] for p in pairs], {p[0]: p[1] if len(p) > 1 else "" for p in pairs}, lines[-1]


try:
    ws = iso.cli("new", "alpha")
    other = iso.cli("new", "beta")
    iso.cli("agent", ws, "terminal", "--name", "shell")
    iso.cli("archive", other)
    cache = iso.tmp / "home" / "cache" / "remote"
    cache.mkdir(parents=True)
    (cache / "cleo.json").write_text(json.dumps([
        {"id": "abc123/main", "workspace": "far", "agent": "main"},
        {"id": "abc123/quiet", "workspace": "far", "agent": "quiet", "hidden": True},
    ]))

    values, about, directive = complete("")
    assert {"ls", "send", "msg", "completion", "help", "browser"} <= set(values), values
    assert not {"__complete", "autopin", "autopr", "progress", "checkstamp", "receive"} & set(values), values
    assert about["ls"].startswith("list agents"), about["ls"]
    assert complete("s")[0] == values, "the shell narrows, not iso"
    assert {"worker", "router", "repo-root", "root", "spawn", "checkhealth"} <= set(values), values
    assert "doctor" not in values, "doctor is checkhealth's hidden old name"
    router, worker = complete("router", "")[0], complete("worker", "")[0]
    assert {"ls", "msg", "pr", "spawn", "promote", "help"} <= set(router), router
    assert "pr" not in worker and "promote" in worker, worker
    assert set(complete("worker", "spawn", "--role", "")[0]) == {"root", "repo-root", "router", "worker"}
    assert f"{ws}/main" in complete("worker", "peek", "")[0]

    values, about, _ = complete("send", "")
    assert {f"{ws}/main", f"{ws}/shell", "alpha/main", "alpha/shell", "cleo:abc123/main"} <= set(values), values
    assert "cleo:abc123/quiet" not in values
    assert about[f"{ws}/main"] == "alpha · main", about
    assert complete("send", f"{ws}/main", "")[0] == [], "free text offers nothing"
    assert complete("send", f"{ws}/main", "hello", "")[0] == []
    assert "cleo:abc123/main" not in complete("rm", "")[0], "rm is this host's only"
    assert set(complete("msg", "")[0]) >= {"parent", "children", f"{ws}/main", "cleo:abc123/main"}
    assert set(complete("move", ws, "")[0]) == {"cleo"}
    assert set(complete("archive", "")[0]) == {ws, "alpha"}
    assert set(complete("unarchive", "")[0]) == {other, "beta"}
    assert set(complete("agent", ws, "")[0]) == {"claude", "codex", "terminal", "command"}
    assert set(complete("agent", ws, "claude", "--role", "")[0]) == {"root", "repo-root", "router", "worker"}
    assert "--hidden" in complete("agent", ws, "claude", "--")[0]
    assert "--hidden" not in complete("agent", ws, "claude", "--hidden", "--")[0], "a used switch isn't offered again"
    assert complete("agent", ws, "claude", "--name", "x", "")[0] == [], "after a flag's value, the args go on"
    assert complete("pin", ws, "")[2] == ":files"
    assert complete("new", "x", "--dir", "")[2] == ":dirs"
    assert set(complete("dir", ws, "")[0]) == {"-"} and complete("dir", ws, "")[2] == ":dirs"
    assert set(complete("task", "")[0]) == {"set", "rm", "ls"}
    assert set(complete("task", "set", "t1", "--status", "")[0]) == {"todo", "doing", "waiting", "blocked", "done"}
    assert set(complete("pilot", "")[0]) == {"request", "keys", "screen", "status", "release"}
    assert set(complete("completion", "")[0]) == {"zsh", "bash"}
    assert complete("bogus", "") == ([], {}, ":")

    started = time.time()
    for _ in range(5):
        complete("send", "")
    per_tab = (time.time() - started) / 5
    print(f"__complete send: {per_tab * 1000:.0f} ms")
    assert per_tab < 0.15, per_tab

    # zsh: the real script under compinit; the builtins it calls print their arguments.
    zsh = r"""
autoload -Uz compinit && compinit -u -d "$TMPDIR_ZCD"
source <(iso completion zsh)
[[ $_comps[iso] == _iso ]] || { echo "not registered"; exit 1; }
_describe() { print -rl -- "${(@P)${@[-1]}}"; }
compadd() { print -rl -- "${(@P)${@[-1]}}"; }
_files() { print -r -- "FILES $*"; }
words=(iso send ''); CURRENT=3; _iso
print -- ---
words=(iso pin %s ''); CURRENT=4; _iso
print -- ---
words=(iso ag); CURRENT=2; _iso
""" % ws
    result = subprocess.run(["zsh", "-f", "-c", zsh], env={**iso.env, "TMPDIR_ZCD": str(iso.tmp / "zcompdump")}, capture_output=True, text=True)
    assert result.returncode == 0 and not result.stderr, result
    sends, pins, firsts = result.stdout.split("---\n")
    assert f"{ws}/main:alpha · main" in sends and "cleo\\:abc123/main:cleo · far · main" in sends, sends
    assert pins.strip() == "FILES", pins
    assert "agent:add an agent (claude|codex|terminal|command), start it" in firsts, firsts

    # bash: the real script, called as readline would; macOS's own bash is 3.2, where source <(...)
    # reads nothing, hence eval.
    bash = r"""
eval "$(iso completion bash)"
complete -p iso; echo ---
try() { COMP_LINE="$1"; COMP_POINT=${#COMP_LINE}; _iso; printf '%s\n' "${COMPREPLY[@]}"; echo ---; }
try "iso sen"
try "iso send "
try "iso send cleo:"
try "iso task set t1 --status d"
"""
    for shell in ("bash", "/bin/bash"):
        result = subprocess.run([shell, "-c", bash], env=iso.env, capture_output=True, text=True)
        assert result.returncode == 0 and not result.stderr, result
        spec, sends, all_sends, colon, status, _ = result.stdout.split("---\n")
        assert "complete -o default -F _iso iso" in spec, spec
        assert sends.split() == ["send"], sends
        assert f"{ws}/main" in all_sends.split() and "cleo:abc123/main" in all_sends.split(), all_sends
        assert colon.split() == ["abc123/main"], (shell, colon)
        assert sorted(status.split()) == ["doing", "done"], status
    print("OK")
finally:
    iso.stop()
