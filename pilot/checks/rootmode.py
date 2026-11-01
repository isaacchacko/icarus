"""Roles and root mode on ACP, with pilot/fake-acp-agent as the adapter (it logs every frame, so
the prompt each session got is in its log).

Promotion: a self-promoted worker's session is closed and resumed with the router's prompt once its
turn ends; one promoted by another is reloaded with the repo-root's prompt and then gets the
promoter's stamped message; router -> root and repo-root -> root fork the agent (session/fork with
the root's prompt), the original keeps its role and the fork is told who made it root. Stamp
authority follows the host root (over the old `iso root` file).

Root mode: with it off a router's question waits in your Inbox; iso rootmode on host spawns a worker
promoted to root, and a router's question goes to it (a stamped message), which answers it with
iso root answer and the router's blocking iso router surface question returns; iso rootmode on
<repo> --task spawns a repo root whose first message is the task, and the repo's questions go to it
(the most specific root), which answers with iso repo-root answer or raises one to your Inbox
(--raise); no root answers another's question; the sidebar's root-mode marker follows the state;
off hands the waiting questions on (repo root -> host root -> you).
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/rootmode.py"""

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


iso = Iso("rootmode", agent_delay=0.3)
iso.env["ISOVIM_SELF"] = "pilothost"
WORK = iso.tmp / "work"
HOME = iso.tmp / "home"


def run(*args, timeout=120):
    r = subprocess.run([BIN, *args], env=iso.env, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout.strip(), r.stderr


def record(address):
    key, agent = address.rsplit("/", 1)
    path = WORK / key / "iso" / "agents" / f"{agent}.json"
    return json.loads(path.read_text()) if path.exists() else None


def journal(address):
    key, agent = address.rsplit("/", 1)
    path = WORK / key / "iso" / "journal" / f"{agent}.jsonl"
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def prompts(address):
    return [e.get("text") or "" for e in journal(address) if e["kind"] == "prompt"]


def session(address):
    return (record(address) or {}).get("session")


def fake_frames():
    path = Path(iso.env["FAKE_ACP_LOG"])
    return [json.loads(line)["frame"] for line in path.read_text().splitlines() if '"frame"' in line] if path.exists() else []


def indexed(method, sid):
    """(index in the fake's log, frame) for each frame of method on session sid."""
    return [(i, f) for i, f in enumerate(fake_frames()) if f.get("method") == method and f.get("params", {}).get("sessionId") == sid]


def opened(address):
    """The session/new frames the agent's supervisor sent (they carry its dir, not a session id)."""
    key, agent = address.rsplit("/", 1)
    want = str((WORK / key / agent).resolve())
    return [f for f in fake_frames() if f.get("method") == "session/new" and str(Path(f["params"]["cwd"]).resolve()) == want]


def append_of(frame):
    return frame["params"].get("_meta", {}).get("systemPrompt", {}).get("append", "")


def surface(repo, name):
    for entry in json.loads(run("__surfaces", repo)[1] or "[]"):
        if entry["name"] == name:
            return entry


counter = [0]


def inside(address, *cmds, timeout=60):
    """Runs each iso command from inside the agent (the fake runs it as its child); [(rc, out, err)]."""
    counter[0] += 1
    d = iso.tmp / f"in{counter[0]}"
    d.mkdir()
    lines = [f"{BIN} {cmd} > {d}/{i}.out 2> {d}/{i}.err; echo $? > {d}/{i}.rc" for i, cmd in enumerate(cmds)]
    lines.append(f"touch {d}/done")
    (d / "s.sh").write_text("\n".join(lines) + "\n")
    rc, _, err = run("send", address, f"run bash {d}/s.sh")
    assert rc == 0, err
    iso.wait(lambda: (d / "done").exists(), f"commands in {address}", timeout)
    return [(int((d / f"{i}.rc").read_text()), (d / f"{i}.out").read_text().strip(), (d / f"{i}.err").read_text())
            for i in range(len(cmds))]


def ask(router, name, question="Ship it?", options=("yes", "no"), repo="acme/app"):
    """The router asks (its turn blocks on it); returns a function giving (rc, out, err) once it returns."""
    d = iso.tmp / f"q-{name}"
    d.mkdir()
    (d / "q.json").write_text(json.dumps({"question": question, "options": [{"label": o} for o in options]}))
    rc, _, err = run("send", router, f"run {BIN} router surface question {d}/q.json --name {name} > {d}/out 2> {d}/err; echo $? > {d}/rc")
    assert rc == 0, err
    iso.wait(lambda: surface(repo, name), f"the question {name}")

    def result(timeout=30):
        iso.wait(lambda: (d / "rc").exists(), f"the router's question {name} to return", timeout)
        return int((d / "rc").read_text()), (d / "out").read_text().strip(), (d / "err").read_text()
    return result


def repo(name):
    path = iso.tmp / "src" / name
    path.mkdir(parents=True)
    git("init", "-q", str(path))
    git("-C", str(path), "remote", "add", "origin", f"git@github.com:Acme/{name}.git")
    return path


try:
    iso.start()
    lab, app = repo("lab"), repo("app")

    print("# promotion reloads the session with the new role's prompt")
    W = run("spawn", "--acp", "--repo", str(lab), "--name", "w")[1]
    R = run("spawn", "--acp", "--repo", str(lab), "--name", "r")[1]
    X = run("spawn", "--acp", "--repo", str(lab), "--name", "x")[1]
    check([W, R, X] == ["acme/lab/a0", "acme/lab/a1", "acme/lab/a2"], "three ACP workers in acme/lab", (W, R, X))
    first = opened(R)
    check(first and "as a worker agent" in append_of(first[0]), "a worker's session opens with the worker's prompt",
          first and append_of(first[0])[:120])

    res = inside(R, "worker promote router")
    check(res[0][0] == 0 and "When this turn ends, isovim reloads your session" in res[0][1], "R promotes itself to router", res[0])
    iso.wait(lambda: any(e["kind"] == "session" and e.get("how") == "reload" for e in journal(R)), "R's reload", 20)
    closes, resumes = indexed("session/close", session(R)), indexed("session/resume", session(R))
    check(len(closes) == 1 and len(resumes) == 1 and closes[0][0] < resumes[0][0], "its session is closed, then resumed", (closes, resumes))
    check(resumes and "as a router agent" in append_of(resumes[0][1]) and "iso router" in append_of(resumes[0][1]),
          "the resumed session has the router's prompt", resumes and append_of(resumes[0][1])[:120])
    reload_seq = next(e["seq"] for e in journal(R) if e.get("how") == "reload")
    turn_end = max(e["seq"] for e in journal(R) if e["kind"] == "turn" and e.get("state") == "end" and e["seq"] < reload_seq)
    check(turn_end < reload_seq, "the reload waits for the turn that promoted it to end", (turn_end, reload_seq))
    check(record(R)["role"] == "router" and run("status", R)[1] != "stopped", "R is a router, its supervisor still up (no restart)")
    check(not any("promoted to" in p for p in prompts(R)), "a self-promotion sends no message", prompts(R))

    res = inside(W, f"worker promote {X} repo-root the lab needs a root")
    check(res[0][0] == 0 and f"{X} is now a repo-root" in res[0][1], "W promotes X to repo-root", res[0])
    iso.wait(lambda: any("You were promoted to repo-root" in p for p in prompts(X)), "X's message", 20)
    sx = session(X)
    close, resume = indexed("session/close", sx), indexed("session/resume", sx)
    told = [(i, f) for i, f in indexed("session/prompt", sx) if "You were promoted to repo-root" in json.dumps(f)]
    check(close and resume and told and close[0][0] < resume[0][0] < told[0][0],
          "X's session is reloaded first, then it gets the message", (close, resume, told))
    check(resume and "as a repo-root agent" in append_of(resume[0][1]), "with the repo-root's prompt", resume and append_of(resume[0][1])[:120])
    msg = next(p for p in prompts(X) if "You were promoted" in p)
    check(msg.startswith(f"[from pilothost:{W} · m") and f"by {W}: the lab needs a root. Your session was reloaded" in msg,
          "the message is stamped from W and says who and why", msg)
    check(record(X)["role"] == "repo-root" and record(X).get("parent") is None, "X is a repo-root with no parent", record(X))

    print("\n# router -> root and repo-root -> root fork")
    run("root", W)
    check(run("root")[1] == "pilothost:" + W, "the old iso root file names W while no agent holds the root role")
    res = inside(W, f"worker promote {R} root the host needs one")
    F1 = "acme/lab/a3"
    check(res[0][0] == 0 and f"{F1} is the root, forked from the router {R}" in res[0][1], "router -> root forks R", res[0])
    iso.wait(lambda: any("made the root by" in p for p in prompts(F1)), "the fork's message", 30)
    forks = indexed("session/fork", session(R))
    check(len(forks) == 1 and "as a root agent" in append_of(forks[0][1]), "the fork's session is session/fork of R's, with the root's prompt",
          forks and append_of(forks[0][1])[:120])
    check(record(F1)["role"] == "root" and record(F1).get("acp") and record(F1).get("session", "").startswith("fork-")
          and record(R)["role"] == "router", "the fork is the root (its own session), R stays the router", (record(F1), record(R)["role"]))
    check(any(e["kind"] == "session" and e.get("how") == "fork" for e in journal(F1)), "the fork's journal says it forked")
    check(any(f"You are a fork of the router {R}, made the root by {W}: the host needs one" in p for p in prompts(F1)),
          "the fork is told who made it root and why", prompts(F1))

    print("\n# stamp authority follows the host root")
    check(run("root")[1] == "pilothost:" + F1, "iso root prints the host root, over the old file", run("root"))
    r = run("root", W)
    check(r[0] != 0 and "the host root is " + F1 in r[2], "and iso root can't name another", r)
    res = inside(F1, f"root msg {W} from-the-root", f"worker msg {W} from-x")
    iso.wait(lambda: any("from-the-root" in p for p in prompts(W)), "the root's message")
    got = next(p for p in prompts(W) if "from-the-root" in p)
    check(got.startswith(f"[from pilothost:{F1} · root · m"), "the host root's messages carry the root stamp", got)
    rm = run("rm", F1)
    check(rm[0] == 0 and record(F1) is None, "removing the root", rm)
    check(run("root")[1] == "pilothost:" + W, "with no root-role agent the old file counts again", run("root"))
    run("root", "--clear")

    res = inside(W, f"worker promote {X} root the host needs one again")
    F2 = "acme/lab/a4"
    check(res[0][0] == 0 and f"{F2} is the root, forked from the repo-root {X}" in res[0][1], "repo-root -> root forks X", res[0])
    iso.wait(lambda: any("made the root by" in p for p in prompts(F2)), "the second fork's message", 30)
    forks = indexed("session/fork", session(X))
    check(len(forks) == 1 and "as a root agent" in append_of(forks[0][1]), "a session/fork of X's, with the root's prompt", forks)
    check(record(X)["role"] == "repo-root" and record(F2)["role"] == "root", "X stays the repo-root", (record(X), record(F2)))
    check(any(f"You are a fork of the repo-root {X}, made the root by {W}" in p for p in prompts(F2)), "the fork is told", prompts(F2))
    check(run("rm", F2)[0] == 0, "removing that root too")

    print("\n# root mode off: a router's question waits on you")
    RA = run("spawn", "--acp", "--repo", str(app), "--role", "router", "--name", "lead")[1]
    check(RA == "acme/app/a0", "an ACP router in acme/app", RA)
    q1 = ask(RA, "q1")
    entry = surface("acme/app", "q1")
    check(entry["needs_you"] and not entry.get("routed"), "q1 is in your Inbox", entry)
    run("answer", "q1", "yes")
    check(q1() == (0, "yes", q1()[2]), "your answer returns the router's call", q1())
    check("root mode" not in "\n".join(iso.sidebar()), "no root-mode marker", iso.sidebar()[:6])

    print("\n# root mode on for the host")
    rc, out, err = run("rootmode", "on", "host")
    HR = "_/a0"
    check(rc == 0 and HR in out and "a new root" in out, "iso rootmode on host spawns the host root", (rc, out, err))
    check(record(HR)["role"] == "root" and record(HR).get("acp"), "a worker promoted to root, over ACP", record(HR))
    new = opened(HR)
    check(new and "as a root agent" in append_of(new[0]), "its session opens with the root's prompt", new)
    state = json.loads((HOME / "rootmode.json").read_text())
    check(state["host"]["agent"] == HR, "rootmode.json says so", state)
    check(run("root")[1] == "pilothost:" + HR, "and it holds your authority")
    iso.wait(lambda: any("Inbox" in l and "root mode" in l for l in iso.sidebar()), "the host Inbox's root-mode marker")
    q2 = ask(RA, "q2")
    entry = surface("acme/app", "q2")
    check(entry.get("routed") == HR and not entry["needs_you"], "q2 goes to the host root, not your Inbox", entry)
    iso.wait(lambda: any("[question acme/app/q2" in p for p in prompts(HR)), "the host root's message")
    got = next(p for p in prompts(HR) if "[question acme/app/q2" in p)
    check(got.startswith(f"[from pilothost:{RA} · m") and "1. yes" in got and "iso root answer acme/app/q2" in got,
          "it gets the question, stamped from the router, with how to answer", got)
    res = inside(HR, "root answer acme/app/q2 no")
    check(res[0][0] == 0, "the host root answers it", res[0])
    check(q2()[:2] == (0, "no"), "and the router's call returns its answer", q2())
    qr = ask(HR, "qr", "Spend money?", repo="root")
    entry = surface("root", "qr")
    check(entry["needs_you"] and not entry.get("routed"), "the host root's own question is yours, never routed to itself", entry)
    run("answer", "root/qr", "no")
    check(qr()[:2] == (0, "no"), "your answer returns the host root's call", qr())

    print("\n# root mode on for the repo, with a task")
    rc, out, err = run("rootmode", "on", "acme/app", "--task", "only the tab line fix")
    RR = "acme/app/a1"
    check(rc == 0 and RR in out, "iso rootmode on acme/app spawns its repo root", (rc, out, err))
    check(record(RR)["role"] == "repo-root", "a repo-root", record(RR))
    iso.wait(lambda: prompts(RR), "the repo root's first prompt")
    check("only the tab line fix" in prompts(RR)[0] and "guidance" in prompts(RR)[0], "its first message is the task", prompts(RR))
    new = opened(RR)
    check(new and "as a repo-root agent" in append_of(new[0]), "its session opens with the repo-root's prompt", new)
    q3 = ask(RA, "q3")
    entry = surface("acme/app", "q3")
    check(entry.get("routed") == RR, "q3 goes to the repo root, the most specific", entry)
    iso.wait(lambda: any("[question acme/app/q3" in p for p in prompts(RR)), "the repo root's message")
    got = next(p for p in prompts(RR) if "[question acme/app/q3" in p)
    check("only the tab line fix" in got and "--raise" in got, "with its task and how to raise it", got)
    marked = iso.wait(lambda: len([l for l in iso.sidebar() if "Inbox" in l and "root mode" in l]) >= 2 and iso.sidebar(), "the markers")
    check(marked, "the host's and the repo's Inbox show the root-mode marker", marked)
    res = inside(HR, "root answer acme/app/q3 yes")
    check(res[0][0] != 0 and f"it waits on {RR}" in res[0][2], "the host root can't answer the repo root's question", res[0])
    res = inside(RR, "repo-root answer acme/app/q3 --raise")
    check(res[0][0] == 0, "the repo root raises q3 (outside its task)", res[0])
    entry = surface("acme/app", "q3")
    check(entry["needs_you"] and not entry.get("routed") and entry.get("raised"), "q3 is in your Inbox now", entry)
    run("answer", "q3", "no")
    check(q3()[:2] == (0, "no"), "your answer returns the router's call", q3())
    q4 = ask(RA, "q4")
    iso.wait(lambda: any("[question acme/app/q4" in p for p in prompts(RR)), "q4 at the repo root")
    res = inside(RR, "repo-root answer acme/app/q4 yes")
    check(res[0][0] == 0 and q4()[:2] == (0, "yes"), "iso repo-root answer unblocks the router", (res[0], q4()))
    answered = [json.loads(l) for l in (HOME / "events" / "events.jsonl").read_text().splitlines() if ".q4.answered" in l]
    check(answered and answered[0]["answer"]["by"] == RR, "the answer says the repo root gave it", answered)

    print("\n# root mode off hands the questions on")
    q5 = ask(RA, "q5")
    iso.wait(lambda: (surface("acme/app", "q5") or {}).get("routed") == RR, "q5 at the repo root")
    rc, out, err = run("rootmode", "off", "acme/app")
    check(rc == 0 and f"acme/app/q5 goes to {HR}" in out, "off for the repo: q5 goes on to the host root", (rc, out, err))
    check(surface("acme/app", "q5").get("routed") == HR, "q5 is routed to the host root", surface("acme/app", "q5"))
    iso.wait(lambda: any("[question acme/app/q5" in p for p in prompts(HR)), "the host root gets q5")
    iso.wait(lambda: any("Root mode is off for acme/app" in p for p in prompts(RR)), "the repo root is told")
    check(record(RR)["role"] == "repo-root", "it keeps its role")
    rc, out, err = run("rootmode", "off", "host")
    check(rc == 0 and "acme/app/q5 goes to the user" in out, "off for the host: q5 comes to you", (rc, out, err))
    entry = surface("acme/app", "q5")
    check(entry["needs_you"] and not entry.get("routed"), "q5 waits in your Inbox", entry)
    iso.wait(lambda: "root mode" not in "\n".join(iso.sidebar()), "the marker gone")
    run("answer", "q5", "yes")
    check(q5()[:2] == (0, "yes"), "and your answer returns it", q5())
    check(run("rootmode", "off", "host")[1] == "root mode is already off for this host", "off twice says so")
    rc, out, err = run("rootmode", "on", "host", "--task", "keep the lab green")
    check(rc == 0 and HR in out and "already" in out, "on again reuses the host root that holds the role", (rc, out, err))
    iso.wait(lambda: any("keep the lab green" in p for p in prompts(HR)), "the task reaches it")
    check(run("rootmode", "on")[0] != 0 and run("rootmode", "on", "_")[0] != 0, "usage and general refused")
finally:
    iso.stop()

print("\nfailures:", len(fails))
for f in fails:
    print("  " + f)
sys.exit(1 if fails else 0)
