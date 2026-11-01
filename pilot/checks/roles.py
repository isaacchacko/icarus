"""Roles on the command line: iso <role> <action> runs the bare command, the warn-only role checks
(who is warned, and that every call still runs), role completion, iso spawn's and iso <role> promote's
rules (the restart, the stamped message, the router made root by a fork), their events, checkhealth.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/roles.py"""
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from iso import REPO, Iso  # noqa: E402

BIN = str(REPO / "bin" / "iso")
fails = []


def check(ok, what, detail=""):
    print(("ok   " if ok else "FAIL ") + what + ("" if ok else f"\n     {detail}"))
    if not ok:
        fails.append(what)


iso = Iso("roles", agent_delay=0.3).start()


def run(*args):
    r = subprocess.run([BIN, *args], env=iso.env, capture_output=True, text=True, timeout=120)
    return r.returncode, r.stdout, r.stderr


def git(*args):
    subprocess.run(["git", *args], check=True, capture_output=True)


def agents():
    return {row["id"]: row for row in json.loads(run("ls", "--json")[1])}


def meta_agent(address):
    ws, agent = address.split("/")
    meta = json.loads((iso.tmp / "home" / "workspaces" / ws / ".isovim.json").read_text())
    return next(a for a in meta.get("agents", [{"id": "main"}]) if a["id"] == agent)


counter = [0]


def inside(address, *cmds, timeout=60):
    """Runs each iso command from inside the agent's pane; returns [(rc, out, err)]."""
    counter[0] += 1
    d = iso.tmp / f"in{counter[0]}"
    d.mkdir()
    lines = []
    for i, cmd in enumerate(cmds):
        lines.append(f"{BIN} {cmd} > {d}/{i}.out 2> {d}/{i}.err; echo $? > {d}/{i}.rc")
    lines.append(f"touch {d}/done")
    (d / "s.sh").write_text("\n".join(lines) + "\n")
    rc, _, err = run("send", address, f"run bash {d}/s.sh")
    assert rc == 0, err
    iso.wait(lambda: (d / "done").exists(), f"commands in {address}", timeout)
    return [(int((d / f"{i}.rc").read_text()), (d / f"{i}.out").read_text(), (d / f"{i}.err").read_text()) for i in range(len(cmds))]


try:
    # Repos: acme/app (two clones), acme/other, acme/third, and a plain dir.
    origin = iso.tmp / "origin" / "acme"
    for name in ("app", "other", "third", "fourth"):
        git("init", "-q", "--bare", str(origin / f"{name}.git"))
    seed = iso.tmp / "seed"
    git("init", "-q", str(seed))
    git("-C", str(seed), "commit", "-q", "--allow-empty", "-m", "x")
    for name in ("app", "other", "third", "fourth"):
        git("-C", str(seed), "push", "-q", str(origin / f"{name}.git"), "HEAD:refs/heads/main")
    dirs = {}
    for name, repo in (("app", "app"), ("app2", "app"), ("other", "other"), ("third", "third"), ("fourth", "fourth")):
        dirs[name] = iso.tmp / name
        git("clone", "-q", str(origin / f"{repo}.git"), str(dirs[name]))
    plain = iso.tmp / "plain"
    plain.mkdir()

    def new(name, d):
        ws = run("new", name, "--dir", str(d))[1].strip()
        run("open", f"{ws}/main")
        return f"{ws}/main"

    A = new("A", dirs["app"])
    W2 = new("W2", dirs["other"])
    W3 = new("W3", dirs["third"])
    P = new("P", plain)
    W4 = new("W4", dirs["app2"])

    print("\n# dispatch: a role namespace runs the bare command")
    for words in (("ls",), ("version",), ("status", A), ("peek", A, "-n", "2"), ("find", "W2", "--local")):
        bare, role = run(*words), run("worker", *words)
        check(bare[0] == role[0] and bare[1] == role[1], f"iso worker {' '.join(words)} == iso {' '.join(words)}", f"{bare} vs {role}")
        check(bare[2] == "", f"user: bare iso {words[0]} doesn't warn", bare[2])
        check("iso: warning: iso worker ... is for agents, and this isn't one" in role[2] and role[2].count("\n") == 1,
              f"user: iso worker {words[0]} warns once", role[2])
    r = run("router", "pr", A.split("/")[0], "acme/app#7")
    check(r[0] == 0 and "warning" in r[2], "user: iso router pr runs (and warns)", r)
    r = run("worker", "pr", A.split("/")[0], "acme/app#7")
    check(r[0] == 1 and "pr isn't a worker action" in r[2], "iso worker pr is refused (not a worker action)", r)
    r = run("worker")
    check(r[0] == 1 and "usage: iso worker <action>" in r[1], "iso worker alone prints its usage, rc 1", r)
    r = run("worker", "help")
    check(r[0] == 0 and "iso worker ls" in r[1] and "iso worker pr " not in r[1] and r[2] == "", "iso worker help", r)
    r = run("router", "help")
    check("iso router pr" in r[1], "iso router help lists pr", r[1][-300:])
    r = run("root")
    check(r == (0, "no root\n", ""), "iso root (old): prints the root, no warning", r)
    run("root", A)
    r = run("root")
    check(r[1].strip().endswith(":" + A), "iso root <agent> (old) still sets it", r)
    run("root", "--clear")
    r = run("root", "help")
    check(r[0] == 0 and "iso root ls" in r[1], "iso root help is the namespace", r)
    r = run("root", "ls")
    check(r[0] == 0 and A in r[1] and "is for agents" in r[2], "iso root ls is the namespace", r)

    print("\n# warnings from inside an agent (A is a worker)")
    res = inside(A, "worker ls", "router ls", "ls", "root msg parent hi", f"task set t1 'thing'", "task ls",
                 f"pr {A.split('/')[0]} acme/app#8", f"send {W2} hello", "move", f"transcript {A}", "worker pr x y",
                 "checkhealth", "doctor", "worker checkhealth", "worker browser help", "browser help", "help",
                 f"agent {A.split('/')[0]} terminal --name t", "root", "router browser help")
    names = ["worker ls", "router ls", "ls", "root msg parent", "task set", "task ls", "pr", "send", "move", "transcript",
             "worker pr", "checkhealth", "doctor", "worker checkhealth", "worker browser help", "browser help", "help",
             "agent", "root", "router browser help"]
    got = dict(zip(names, res))

    def warned(name, text=None):
        err = got[name][2]
        lines = [line for line in err.splitlines() if line.startswith("iso: warning:")]
        return len(lines) == 1 and (text is None or text in lines[0])

    def silent(name):
        return "iso: warning" not in got[name][2]

    check(silent("worker ls") and got["worker ls"][0] == 0, "iso worker ls: no warning", got["worker ls"])
    check(warned("router ls", "you are a worker, not a router: run iso worker ls (this will be refused later)") and got["router ls"][0] == 0,
          "iso router ls as a worker: warns, runs", got["router ls"])
    check(got["router ls"][1] == got["worker ls"][1], "iso router ls prints what iso worker ls does")
    check(warned("ls", "agents run iso worker ls;") and got["ls"][0] == 0, "bare iso ls from an agent: warns, runs", got["ls"])
    check(warned("root msg parent", "you are a worker, not a root: run iso worker msg"), "iso root msg as a worker warns", got["root msg parent"])
    check(silent("task set") and silent("task ls") and "thing" in got["task ls"][1], "iso task (legacy, no role form): no warning", got["task ls"])
    check(silent("pr") and got["pr"][0] == 0, "iso pr from a worker (only a router's role form): no warning", got["pr"])
    check(warned("send", "agents run iso worker msg, not iso send") and got["send"][0] == 0, "bare iso send: warns toward msg", got["send"])
    check(warned("move", "iso move is the user's") and got["move"][0] == 1 and "usage" in got["move"][2], "bare iso move: warns, then its own usage", got["move"])
    check(silent("transcript") and got["transcript"][0] == 0, "iso transcript (plumbing): no warning", got["transcript"])
    check(got["worker pr"][0] == 1 and silent("worker pr"), "iso worker pr from an agent: refused, no warning", got["worker pr"])
    check(warned("checkhealth", "agents run iso worker checkhealth;"), "bare iso checkhealth warns", got["checkhealth"])
    check(warned("doctor", "agents run iso worker checkhealth, not iso doctor"), "bare iso doctor warns toward checkhealth", got["doctor"])
    check(silent("worker checkhealth") and got["worker checkhealth"][1] == got["checkhealth"][1], "iso worker checkhealth = iso checkhealth", got["worker checkhealth"])
    check(silent("worker browser help") and got["worker browser help"][0] == 0 and got["worker browser help"][1] == got["browser help"][1],
          "iso worker browser help = iso browser help, no warning", got["worker browser help"][1][:200])
    check(warned("browser help", "agents run iso worker browser;"), "bare iso browser from an agent warns", got["browser help"])
    check(warned("router browser help", "you are a worker, not a router: run iso worker browser"), "iso router browser as a worker warns", got["router browser help"])
    check(silent("help"), "iso help: no warning", got["help"])
    check(warned("agent", "agents run iso worker spawn, not iso agent") and got["agent"][0] == 0, "bare iso agent: warns toward spawn, runs", got["agent"])
    check(silent("root") and got["root"][1] == "no root\n", "bare iso root (old, no role form): no warning", got["root"])
    r = run("browser", "help")
    check(r[2] == "" and r[1] == got["browser help"][1], "user: iso browser help, no warning", r[2])
    # A terminal agent is the user typing.
    term = run("agent", A.split("/")[0], "terminal", "--name", "term")[1].strip()
    tdir = iso.tmp / "term"
    tdir.mkdir()
    run("send", term, f"{BIN} ls 2> {tdir}/ls.err; {BIN} worker ls 2> {tdir}/wls.err; touch {tdir}/done")
    iso.wait(lambda: (tdir / "done").exists(), "terminal commands", 30)
    check((tdir / "ls.err").read_text() == "", "bare iso ls from a terminal agent: no warning", (tdir / "ls.err").read_text())
    check("is for agents, and this isn't one" in (tdir / "wls.err").read_text(), "iso worker ls from a terminal agent: the user's warning", (tdir / "wls.err").read_text())
    run("rm", term)

    print("\n# completion")
    first = run("__complete", "")[1]
    check(all(f"\n{r}\t" in "\n" + first for r in ("worker", "router", "repo-root", "root", "spawn", "checkhealth")), "first word offers roles, spawn, checkhealth", first)
    check("\ndoctor" not in "\n" + first, "doctor is hidden from completion")
    router = [line.split("\t")[0] for line in run("__complete", "router", "")[1].splitlines()]
    worker = [line.split("\t")[0] for line in run("__complete", "worker", "")[1].splitlines()]
    check("pr" in router and "pr" not in worker and "promote" in worker and "spawn" in worker and "help" in worker,
          "iso router <Tab> has pr, iso worker <Tab> doesn't", f"{router} / {worker}")
    check(set(worker) - {":"} == {"msg", "ls", "status", "peek", "wait", "find", "transcript", "browser", "checkhealth", "version", "pilot",
                                  "fork", "spawn", "promote", "help", "wt", "setup", "teardown", "run"}
          | ({"listen"} if "listen" in worker else set()), "worker actions", worker)
    r = run("__complete", "worker", "spawn", "--role", "")[1].split()
    check({"worker", "router", "repo-root", "root"} <= set(r), "iso worker spawn --role <Tab> lists roles", r)
    r = run("__complete", "root", "")[1]
    check(A in r and "\nls\t" in "\n" + r, "iso root <Tab>: agents (old iso root) and the root's actions", r[:300])
    r = run("__complete", "worker", "status", "")[1]
    check(A in r, "iso worker status <Tab> lists agents", r[:200])
    r = run("__complete", "worker", "pilot", "")[1].split()
    check("request" in r, "iso worker pilot <Tab> lists subcommands", r)

    print("\n# spawn")
    r = run("spawn", "--repo", str(dirs["app"]), "--role", "router", "--name", "R", "route", "app")
    R = r[1].strip()
    check(r[0] == 0 and R.endswith("/main") and r[2] == "", "user spawns a router in acme/app", r)
    rec = agents()[R]
    check(rec["role"] == "router" and rec.get("parent") is None and rec["status"] != "stopped", "the router is running, parentless", rec)
    check(meta_agent(R).get("prompt") == "route app", "its prompt is the words", meta_agent(R))
    r = run("spawn", "--repo", str(dirs["app2"]), "--role", "router")
    check(r[0] == 1 and "acme/app already has a router here: " + R in r[2], "a second router for acme/app (other clone) is refused", r)
    r = run("spawn", "--role", "router")
    check(r[0] == 1 and "a router is a repo's" in r[2], "a router outside a repo is refused", r)
    r = run("spawn", "--repo", "acme/app", "--read-only", "--name", "ro", "look")
    RO = r[1].strip()
    check(r[0] == 0 and "nothing enforces it yet" in r[2] and meta_agent(RO).get("read_only") is True, "--repo owner/repo finds the clone; --read-only is recorded", r)
    check(agents()[RO]["dir"].endswith("/app") or agents()[RO]["dir"].endswith("/app2"), "it runs in a clone of acme/app", agents()[RO]["dir"])
    r = run("spawn", "--repo", "acme/nowhere")
    check(r[0] == 1 and "no clone of acme/nowhere" in r[2], "an unknown owner/repo is refused", r)
    res = inside(A, "worker spawn kid task", "worker spawn --role router --repo " + str(dirs["fourth"]), "worker spawn --role root")
    kid = res[0][1].strip()
    check(res[0][0] == 0 and agents()[kid]["parent"] == A and agents()[kid]["dir"] == agents()[A]["dir"], "a worker spawns a worker: its child, in its project", res[0])
    check(res[1][0] == 1 and "a worker spawns roles up to its own, and router is higher" in res[1][2], "a worker can't spawn a router", res[1])
    check(res[2][0] == 1 and "root is higher" in res[2][2], "a worker can't spawn a root", res[2])
    res = inside(R, f"router spawn --role router --repo {dirs['fourth']} r4", "router spawn --role repo-root", "router spawn helper")
    R4 = res[0][1].strip()
    check(res[0][0] == 0 and agents()[R4]["role"] == "router" and agents()[R4]["parent"] == R, "a router spawns a router for another repo (its child)", res[0])
    check(res[1][0] == 1 and "repo-root is higher" in res[1][2], "a router can't spawn a repo-root", res[1])
    check(res[2][0] == 0 and agents()[res[2][1].strip()]["parent"] == R, "a router spawns a worker", res[2])
    run("rm", R4)

    print("\n# promotion")
    res = inside(W4, "worker promote router")
    check(res[0][0] == 1 and "acme/app already has a router here: " + R in res[0][2], "worker -> router where the repo has one: refused", res[0])
    res = inside(P, "worker promote router")
    check(res[0][0] == 1 and "isn't in a git repo" in res[0][2], "worker -> router outside git: refused", res[0])
    r = run("worker", "promote", W2, "router")
    check(r[0] == 1 and "only agents promote agents" in r[2], "the user can't promote", r)
    # Self-promotion: W2 -> router; it restarts once its turn ends, with ISOVIM_ROLE=router, no message.
    res = inside(W2, "worker promote router")
    check(res[0][0] == 0 and "You are now a router. End your turn now" in res[0][1], "worker W2 promotes itself to router", res[0])
    check(agents()[W2]["role"] == "router", "its record says router")
    log = iso.tmp / "home" / "run" / "promote.log"
    iso.wait(lambda: log.exists() and W2 in log.read_text(), "W2 restarted", 30)
    time.sleep(1)
    res = inside(W2, "router ls")
    env_out = iso.tmp / "env.txt"
    run("send", W2, f"run echo ROLE=$ISOVIM_ROLE > {env_out}")
    iso.wait(lambda: env_out.exists() and env_out.read_text().strip(), "W2's env", 20)
    check(env_out.read_text().strip() == "ROLE=router", "after its restart, W2 runs with ISOVIM_ROLE=router", env_out.read_text())
    check(silent("worker ls") and "iso: warning" not in res[0][2], "iso router ls from W2 no longer warns", res[0])
    peek = run("peek", W2, "-n", "60")[1]
    check("promoted to" not in peek, "a self-promotion sends no message", peek[-400:])
    res = inside(W2, "router promote worker", f"router promote {W2} router")
    check(res[0][0] == 1 and "no demotion" in res[0][2], "router -> worker: no demotion", res[0])
    check(res[1][0] == 1 and "already a router" in res[1][2], "router -> router: already one", res[1])
    # Promoted by another: A promotes W3 to repo-root, with a reason; W3 restarts and gets a stamped message.
    run("worker", "status", W3)
    res = inside(A, f"worker promote {W3} repo-root the third repo needs a root")
    check(res[0][0] == 0 and f"{W3} is now a repo-root" in res[0][1], "A promotes W3 to repo-root", res[0])
    iso.wait(lambda: "promoted to repo-root" in run("peek", W3, "-n", "40")[1], "W3's message", 40)
    peek = run("peek", W3, "-n", "40")[1]
    check(f"You were promoted to repo-root by {A}: the third repo needs a root" in peek and "[from " in peek, "W3 gets a stamped message with who and why", peek[-600:])
    peek = iso.wait(lambda: (lambda p: p if "hook:" in p else None)(run("peek", W3, "-n", "40")[1]), "W3 hook", 20)
    check("verified" in peek.lower(), "the stamp is checked on arrival", peek[-600:])
    check(agents()[W3]["role"] == "repo-root" and agents()[W3].get("parent") is None, "W3 is a repo-root with no parent")
    res = inside(A, f"worker promote {W3} root")
    check(res[0][0] == 1 and "a repo-root isn't promoted to root" in res[0][2], "repo-root -> root isn't a promotion", res[0])
    # Router -> root: R gets forked; the fork is root, R stays router; the fork is told by A.
    ws_r = R.split("/")[0]
    (iso.tmp / "home" / "run" / ws_r).mkdir(parents=True, exist_ok=True)
    (iso.tmp / "home" / "run" / ws_r / "main.session").write_text("11111111-2222-4333-8444-555555555555\n")
    before = set(agents())
    res = inside(A, f"worker promote {R} root the host needs one")
    new_ids = set(agents()) - before
    check(res[0][0] == 0 and "is the root, forked from the router " + R in res[0][1] and len(new_ids) == 1, "router -> root forks it", res[0])
    fork = new_ids.pop() if new_ids else None
    if fork:
        rec = agents()[fork]
        check(rec["role"] == "root" and rec.get("parent") is None, "the fork is the root, with no parent", rec)
        check(meta_agent(fork).get("fork_of") == "11111111-2222-4333-8444-555555555555", "the fork starts from R's conversation", meta_agent(fork))
        check(agents()[R]["role"] == "router", "R stays the router")
        iso.wait(lambda: "made the root by" in run("peek", fork, "-n", "40")[1], "the fork's message", 30)
        peek = run("peek", fork, "-n", "40")[1]
        check(f"You are a fork of the router {R}, made the root by {A}: the host needs one" in peek, "the fork is told who made it root and why", peek[-500:])
    res = inside(W4, "worker promote root")
    check(res[0][0] == 1 and "this host already has a root: " + str(fork) in res[0][2], "a second root is refused", res[0])
    r = run("spawn", "--role", "root")
    check(r[0] == 1 and "this host already has a root" in r[2], "spawning a second root is refused", r)

    print("\n# events")
    evs = [json.loads(line) for line in (iso.tmp / "home" / "events" / "events.jsonl").read_text().splitlines()]
    topics = [e["topic"] for e in evs]
    def at(addr):  # <scope>.<id>, each encoded as isovim.events.encode does
        return ".".join(part.replace("%", "%25").replace(".", "%2E") for part in str(addr).rsplit("/", 1))
    check(f"agent.{at(W2)}.promoted" in topics and f"agent.{at(W3)}.promoted" in topics, "promotions publish agent.<scope>.<id>.promoted", topics[-20:])
    check(any(e["topic"] == f"msg.{at(W3)}" and "promoted to repo-root" in e.get("text", "") for e in evs), "the promotion message publishes msg.<scope>.<id>")
    if fork:
        check(any(e["topic"] == f"agent.{at(fork)}.promoted" and e.get("fork_of") == R for e in evs), "the root fork publishes promoted, fork_of the router")

    print("\n# checkhealth")
    a, b = run("checkhealth"), run("doctor")
    check(a[0] == b[0] and a[1] == b[1] and "iso" in a[1], "iso doctor runs checkhealth", (a, b))
    h = run("help")[1]
    check("iso checkhealth" in h and "iso doctor" not in h, "iso help lists checkhealth, not doctor")
finally:
    iso.stop()

print("\nfailures:", len(fails))
for f in fails:
    print("  " + f)
sys.exit(1 if fails else 0)
