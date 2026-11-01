"""The words agents are told, with pilot/fake-acp-agent as the adapter (it logs every frame, so the
prompt each session got is in its log).

isovim seeds ~/.isovim/prompts/{worker,router,repo-root,root}.md from prompts/ in the tree on first
run, never over a file that's there, and names each in config.json's prompts only for a role that
has no entry (one set to a file, or null, is kept, and the file's other keys stay). Each role's ACP
agent opens its session with isovim's words for its role (iso <role> <action>, no iso task, pin or
ask) and then its role's prompt file; a workspace (legacy) agent is still told the legacy words,
without a seeded prompt nobody edited. A seeded file deleted comes back on the next launch.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/prompts.py"""

import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from iso import REPO, Iso  # noqa: E402

BIN = str(REPO / "bin" / "iso")
fails = []


def check(ok, what, detail=""):
    print(("ok   " if ok else "FAIL ") + what + ("" if ok else f"\n     {detail}"))
    if not ok:
        fails.append(what)


def git(*args):
    subprocess.run(["git", *args], check=True, capture_output=True)


iso = Iso("prompts", agent_delay=0.3)
iso.env["ISOVIM_SELF"] = "pilothost"
HOME = Path(iso.env["ISOVIM_HOME"])
WORK = iso.tmp / "work"
PROMPTS = HOME / "prompts"
SHIPPED = REPO / "prompts"
ROLES = ["worker", "router", "repo-root", "root"]


def run(*args, timeout=120):
    r = subprocess.run([BIN, *args], env=iso.env, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout.strip(), r.stderr


def fake_frames():
    path = Path(iso.env["FAKE_ACP_LOG"])
    return [json.loads(line)["frame"] for line in path.read_text().splitlines() if '"frame"' in line] if path.exists() else []


def append_for(address):
    key, agent = address.rsplit("/", 1)
    want = str((WORK / key / agent).resolve())
    for f in fake_frames():
        if f.get("method") == "session/new" and str(Path(f["params"]["cwd"]).resolve()) == want:
            return f["params"].get("_meta", {}).get("systemPrompt", {}).get("append", "")
    return None


def config():
    return json.loads((HOME / "config.json").read_text())


# Before the first run: a router prompt of the user's own where the seed would go, a root prompt
# set to a file elsewhere, and a key of their own in config.json.
HOME.mkdir(parents=True)
PROMPTS.mkdir()
(PROMPTS / "router.md").write_text("MY OWN ROUTER WORDS\n")
mine = iso.tmp / "my-root.md"
mine.write_text("MY OWN ROOT WORDS\n")
(HOME / "config.json").write_text(json.dumps({"repo_dirs": ["~/elsewhere"], "prompts": {"root": str(mine)}}, indent=2))

try:
    iso.start()

    print("# seeded on first run")
    iso.wait(lambda: all((PROMPTS / f"{r}.md").exists() for r in ROLES), "the prompt files")
    for role in ("worker", "repo-root", "root"):
        check((PROMPTS / f"{role}.md").read_text() == (SHIPPED / f"{role}.md").read_text(), f"{role}.md is the shipped default")
    check((PROMPTS / "router.md").read_text() == "MY OWN ROUTER WORDS\n", "the user's router.md isn't written over")
    cfg = config()
    check(cfg.get("repo_dirs") == ["~/elsewhere"], "config.json keeps its own keys", cfg)
    check(cfg["prompts"].get("root") == str(mine), "a role's prompt the user set is kept", cfg["prompts"])
    check(all(cfg["prompts"].get(r) == str(PROMPTS / f"{r}.md") for r in ("worker", "router", "repo-root")),
          "the roles with none are named in config.json (absolute, as this home isn't ~/.isovim)", cfg["prompts"])

    print("\n# each role's agent gets its role's words and prompt")
    app = iso.tmp / "src" / "app"
    app.mkdir(parents=True)
    git("init", "-q", str(app))
    git("-C", str(app), "remote", "add", "origin", "git@github.com:Acme/app.git")
    addresses = {}
    for role in ROLES:
        rc, out, err = run("spawn", "--repo", str(app), "--role", role, "--name", role)
        check(rc == 0, f"spawn a {role}", err)
        addresses[role] = out
    for role in ROLES:
        iso.wait(lambda: append_for(addresses[role]) is not None, f"{role}'s session")
    told = {role: append_for(addresses[role]) for role in ROLES}
    own = {"worker": "As a worker", "router": "As the router", "repo-root": "As the repo-root", "root": "As the host root"}
    prompt = {"worker": "# Worker", "router": "MY OWN ROUTER WORDS", "repo-root": "# Repo root", "root": "MY OWN ROOT WORDS"}
    for role in ROLES:
        text = told[role]
        check(text.startswith(f"You are running inside isovim, as a {role} agent") and f"`iso {role} <action>`" in text,
              f"the {role} is told its role and runs iso {role} <action>", text[:160])
        check(own[role] in text and all(own[r] not in text for r in ROLES if r != role), f"the {role} gets its own role's words only")
        check(prompt[role] in text and text.index(prompt[role]) > text.index(own[role]), f"then its prompt file", text[-300:])
        check("iso task set" not in text and "iso pin " not in text and 'iso ask "' not in text and "$ISOVIM_WS" not in text,
              f"the {role} isn't told the retired commands' usage")
        check("iso task" in text and "retired" in text, f"the {role} is told what replaces them")
    check("iso router surface question" in told["router"] and "iso router pr" in told["router"] and "tasks.md" in told["router"],
          "the router is told surfaces, PR registration and tasks.md")
    check("iso worker wt" in told["worker"] and "iso router setup" in told["router"] and "wt [" not in told["root"],
          "workers and routers are told wt/setup/run; roots aren't")
    check("--raise" in told["repo-root"] and "iso root answer" in told["root"], "roots are told answer and --raise")
    check(all("iso %s listen" % r in told[r] and "msg parent" in told[r] for r in ROLES), "every role is told listen and msg parent")
    rc, _, err = run("router", "pr", "acme/app", "acme/app#7")
    check(rc == 0, "iso router pr <owner/repo> <pr>, as the router is told, takes the repo key", err)

    print("\n# a workspace agent still gets the legacy words")
    legacy = iso.lua("""
      local panes = require("isovim.panes")
      return panes.instructions({ id = "main", kind = "claude", role = "worker" }, "abc123")
    """)
    check("workspace $ISOVIM_WS" in legacy and "iso task set" in legacy and "As a worker" not in legacy,
          "the legacy text, with iso task and iso pin", legacy[:160])
    check("# Worker" not in legacy, "without the seeded worker prompt nobody edited")
    (PROMPTS / "worker.md").write_text("# Worker\n\nEDITED BY THE USER\n")
    legacy = iso.lua("""
      return require("isovim.panes").instructions({ id = "main", kind = "claude", role = "worker" }, "abc123")
    """)
    check("EDITED BY THE USER" in legacy, "but with one the user edited")

    print("\n# the next launch reseeds what's missing and keeps the rest")
    (PROMPTS / "repo-root.md").unlink()
    cfg = config()
    cfg["prompts"]["repo-root"] = None
    (HOME / "config.json").write_text(json.dumps(cfg, indent=2))
    iso.close_tui()
    iso.start()
    iso.wait(lambda: (PROMPTS / "repo-root.md").exists(), "repo-root.md again")
    check((PROMPTS / "worker.md").read_text() == "# Worker\n\nEDITED BY THE USER\n", "the edited worker.md is kept")
    check((PROMPTS / "router.md").read_text() == "MY OWN ROUTER WORDS\n", "and the user's router.md")
    check(config()["prompts"].get("repo-root", "missing") is None, "a role set to null stays null", config()["prompts"])
finally:
    iso.stop()

print(f"\n{len(fails)} failure(s)" if fails else "\nall ok")
sys.exit(1 if fails else 0)
