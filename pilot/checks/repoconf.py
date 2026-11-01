"""A repo's personal config (isovim.repoconf): its scripts are imported once from the repo's own
.superset/config.json (or .isovim/config.json, which wins) and never over keys already there; scripts
read the personal config first and fall back to the repo's file; a sibling script named first in a
command runs by its absolute path; a legacy worktree workspace runs the personal setup; the base clone
is made from a local checkout with origin's refs only, stands alone, and is fetched when called again;
work dirs land under ISOVIM_WORK; base clones don't count as repo configs for colors.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/repoconf.py"""

import json
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from iso import REPO, Iso  # noqa: E402

PALETTE = ["red", "orange", "yellow", "lime", "green", "teal", "cyan", "sky", "blue", "purple", "magenta", "pink"]


def git(*args, cwd=None):
    result = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=True)
    return result.stdout.strip()


def commit(checkout, files, message):
    for name, text in files.items():
        path = checkout / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    git("add", "-A", cwd=checkout)
    git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", message, cwd=checkout)


def make_repo(iso, owner, name, files):
    """A bare "remote" at <tmp>/remotes/<owner>/<name>.git and a checkout of it with files committed."""
    remote = iso.tmp / "remotes" / owner / f"{name}.git"
    remote.mkdir(parents=True)
    git("init", "-q", "--bare", "-b", "main", str(remote))
    checkout = iso.tmp / "src" / name
    git("clone", "-q", str(remote), str(checkout))
    git("checkout", "-qb", "main", cwd=checkout)
    commit(checkout, files, "first")
    git("push", "-q", "-u", "origin", "main", cwd=checkout)
    git("remote", "set-head", "origin", "main", cwd=checkout)
    return remote, checkout


def personal(iso, name):
    return iso.tmp / "home" / "repos" / name / "config.json"


def line(iso, checkout, which):
    return iso.lua("return require('isovim.scripts').line(...)", str(checkout), str(checkout), "w", which)


iso = Iso("repoconf")
try:
    superset = {"setup": ["touch setup-ran"], "teardown": ["echo bye"], "run": ["echo run"]}
    app_remote, app = make_repo(iso, "acme", "app", {".superset/config.json": json.dumps(superset), "config.json": '{"color": "red"}', "sub/config.json": '{"color": "red"}'})
    # A branch only the checkout has, and checked out there: the base clone must not take it.
    git("checkout", "-qb", "isaac/local-only", cwd=app)
    # .isovim/config.json wins over .superset/config.json.
    _, both = make_repo(iso, "acme", "both", {".superset/config.json": json.dumps(superset), ".isovim/config.json": '{"setup": ["echo isovim"]}'})
    # Already has a script: never imported, and the other scripts still come from the repo's file.
    lib_remote, lib = make_repo(iso, "acme", "lib", {".superset/config.json": json.dumps(superset)})
    lib_config = personal(iso, "acme/lib")
    lib_config.parent.mkdir(parents=True)
    lib_config.write_text('{"color": "teal", "run": ["echo mine"]}\n')
    # Not JSON: never written.
    _, bad = make_repo(iso, "acme", "bad", {".superset/config.json": json.dumps(superset)})
    personal(iso, "acme/bad").parent.mkdir(parents=True)
    personal(iso, "acme/bad").write_text("{nope")
    # No scripts of its own: nothing recorded, so a file added later is still imported.
    _, plain = make_repo(iso, "acme", "plain", {"README": "x"})
    iso.start()

    # Import, once.
    assert iso.cli("repo", "import", str(app)).startswith("imported into"), "app import"
    app_config = json.loads(personal(iso, "acme/app").read_text())
    assert {k: app_config[k] for k in ("setup", "teardown", "run")} == superset, app_config
    assert app_config["imported_from"] == str(app / ".superset/config.json"), app_config
    assert app_config["imported_at"].endswith("Z"), app_config
    before = personal(iso, "acme/app").read_text()
    commit(app, {".superset/config.json": json.dumps({"setup": ["echo changed"]})}, "change scripts")
    assert iso.cli("repo", "import", str(app)) == "nothing to import"
    assert personal(iso, "acme/app").read_text() == before

    iso.cli("repo", "import", str(both))
    both_config = json.loads(personal(iso, "acme/both").read_text())
    assert both_config["setup"] == ["echo isovim"], both_config
    # Every script taken out by hand: the recorded import still stops another.
    del both_config["setup"]
    personal(iso, "acme/both").write_text(json.dumps(both_config))
    assert iso.cli("repo", "import", str(both)) == "nothing to import"
    assert iso.cli("repo", "import", str(lib)) == "nothing to import"
    assert lib_config.read_text() == '{"color": "teal", "run": ["echo mine"]}\n', lib_config.read_text()
    assert iso.cli("repo", "import", str(bad)) == "nothing to import"
    assert personal(iso, "acme/bad").read_text() == "{nope"
    assert iso.cli("repo", "import", str(plain)) == "nothing to import"
    assert "imported_from" not in json.loads(personal(iso, "acme/plain").read_text() if personal(iso, "acme/plain").exists() else "{}")
    commit(plain, {".isovim/config.json": '{"run": ["echo late"]}'}, "scripts")
    assert iso.cli("repo", "import", str(plain)).startswith("imported into")

    # Scripts: personal first, the repo's file for what it lacks; a lookup alone imports too.
    assert line(iso, lib, "run").endswith("; echo mine"), line(iso, lib, "run")
    assert line(iso, lib, "setup").endswith("; touch setup-ran"), line(iso, lib, "setup")
    assert line(iso, bad, "setup").endswith("; touch setup-ran"), line(iso, bad, "setup")
    _, fresh = make_repo(iso, "acme", "fresh", {".superset/config.json": json.dumps(superset)})
    assert line(iso, fresh, "run").endswith("; echo run")
    assert json.loads(personal(iso, "acme/fresh").read_text())["imported_from"] == str(fresh / ".superset/config.json")

    # A sibling script runs by absolute path; the personal config beats the changed repo file.
    folder = personal(iso, "acme/app").parent
    (folder / "mark.sh").write_text('#!/bin/sh\ntouch "$SUPERSET_WORKSPACE_PATH/from-personal"\n')
    (folder / "mark.sh").chmod(0o755)
    app_config["setup"] = ["./mark.sh", "echo not-a-file arg"]
    app_config["actions"] = {"lint": ["mark.sh --fix"]}
    personal(iso, "acme/app").write_text(json.dumps(app_config))
    setup = line(iso, app, "setup")
    assert setup.endswith(f"; '{folder}/mark.sh' && echo not-a-file arg"), setup
    assert iso.lua("return require('isovim.repoconf').action('acme/app', 'lint')") == [f"'{folder}/mark.sh' --fix"]
    assert iso.lua("return require('isovim.repoconf').action('acme/app', 'nope')") is None

    # A legacy worktree workspace runs the personal setup in its worktree.
    git("checkout", "-q", "main", cwd=app)
    ws = iso.cli("new", "wt", "--dir", str(app), "--worktree")
    tree = Path(iso.lua("return require('isovim.store').dir(...)", ws))
    iso.wait(lambda: (tree / "from-personal").exists(), "personal setup ran in the worktree", timeout=20)
    assert not (tree / "setup-ran").exists()
    git("checkout", "-q", "isaac/local-only", cwd=app)

    # Base clone: a checkout of another repo is refused, then made from the checkout.
    git("push", "-q", "origin", "isaac/local-only:soon-gone", cwd=app)
    refused = subprocess.run([str(REPO / "bin" / "iso"), "repo", "base", "acme/app", "--from", str(lib)], env=iso.env, capture_output=True, text=True)
    assert refused.returncode == 1 and "not a checkout of acme/app" in refused.stderr, refused
    base = Path(iso.cli("repo", "base", "acme/app", "--from", str(app)))
    assert base == iso.tmp / "home" / "repos" / "acme" / "app" / "base-clone", base
    assert git("remote", "get-url", "origin", cwd=base) == str(app_remote)
    assert git("for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes", cwd=base).split() == ["refs/remotes/origin/HEAD", "refs/remotes/origin/main", "refs/remotes/origin/soon-gone"]
    assert git("rev-parse", "HEAD", cwd=base) == git("rev-parse", "origin/main", cwd=base)
    assert subprocess.run(["git", "-C", str(base), "symbolic-ref", "-q", "HEAD"]).returncode != 0, "detached"
    assert not (base / ".git/objects/info/alternates").exists()
    assert not list((iso.tmp / "home" / "repos" / "acme" / "app").glob("base-clone.*.tmp"))

    # Called again: the same clone, fetched.
    git("checkout", "-q", "main", cwd=app)
    commit(app, {"new": "x"}, "later")
    git("push", "-q", "origin", "main", cwd=app)
    git("push", "-q", "origin", "--delete", "soon-gone", cwd=app)
    assert iso.cli("repo", "base", "acme/app") == str(base)
    assert git("for-each-ref", "--format=%(refname)", "refs/remotes", cwd=base).split() == ["refs/remotes/origin/HEAD", "refs/remotes/origin/main"]
    assert git("rev-parse", "origin/main", cwd=base) == git("rev-parse", "HEAD", cwd=app)

    # Found without --from (lib is a workspace's project), and it stands alone once the checkout goes.
    iso.cli("new", "lib", "--dir", str(lib))
    lib_base = Path(iso.cli("repo", "base", "acme/lib"))
    assert git("remote", "get-url", "origin", cwd=lib_base) == str(lib_remote)
    shutil.rmtree(lib)
    git("fsck", "--full", cwd=lib_base)
    git("fetch", "-q", "origin", cwd=lib_base)
    nowhere = subprocess.run([str(REPO / "bin" / "iso"), "repo", "base", "acme/nowhere"], env=iso.env, capture_output=True, text=True)
    assert nowhere.returncode == 1 and "no checkout of acme/nowhere" in nowhere.stderr, nowhere

    # Work dirs, under ISOVIM_WORK.
    work = iso.lua("return require('isovim.repoconf').work('acme/app')")
    assert work == str(iso.tmp / "work" / "acme" / "app"), work
    assert (Path(work) / "iso" / "transcripts").is_dir()
    assert iso.lua("return require('isovim.repoconf').work('acme/app')") == work

    # The config.json files inside base-clone/ don't count as colors taken.
    taken = sum(1 for p in (iso.tmp / "home" / "repos").rglob("config.json") if "base-clone" not in p.parts and "color" in p.read_text())
    _, newer = make_repo(iso, "acme", "newer", {"README": "x"})
    color = iso.lua("return require('isovim.repos').style('acme/newer').color")
    expected = iso.lua("return require('isovim.repos').palette[...]", PALETTE[taken % 12])
    assert color == expected, (color, expected, taken)
    print("OK")
finally:
    iso.stop()
