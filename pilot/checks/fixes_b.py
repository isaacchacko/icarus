"""Lane B of the spec review's fix list (authority and routing), with pilot/fake-acp-agent as the adapter.

6. The root the `iso root` file names holds the root's place while it's here: a worker can't promote
   itself over it, iso role and iso spawn --role root are refused, and only iso rootmode on host
   takes it over, telling it so. With the holder gone the file counts again, and with the file's
   root gone too, iso ask raises to the user.
7. A root's waiting questions are routed on when it goes: iso rm hands them on, and a router waiting
   on a root removed some other way routes its question on itself (the Inbox counts it meanwhile). A
   question is marked routed only once the root has it: a root the send fails for is passed over,
   for the next root or the user.
8. A real stamp from an address with "root" in it (acme/root-tools) verifies, and iso answer from
   one of isovim's terminals is the user's.
9. A journal line over 64 KiB neither freezes the follower nor resets seq after a restart.
Also: ~/.isovim/prompts/ syncs to the other hosts, never over a newer file there.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/fixes_b.py"""

import json
import os
import re
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


def git(*args):
    subprocess.run(["git", *args], check=True, capture_output=True)


iso = Iso("fixes_b", agent_delay=0.3)
iso.env["ISOVIM_SELF"] = "pilothost"
WORK = iso.tmp / "work"
HOME = iso.tmp / "home"


def run(*args, timeout=120, env=None):
    r = subprocess.run([BIN, *args], env=env or iso.env, capture_output=True, text=True, timeout=timeout)
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


def ask(router, name, repo="acme/app"):
    """The router asks (its turn blocks on it); returns (result(), its stderr so far)."""
    d = iso.tmp / f"q-{name}"
    d.mkdir()
    (d / "q.json").write_text(json.dumps({"question": f"Ship {name}?", "options": [{"label": "yes"}, {"label": "no"}]}))
    rc, _, err = run("send", router, f"run {BIN} router surface question {d}/q.json --name {name} > {d}/out 2> {d}/err; echo $? > {d}/rc")
    assert rc == 0, err
    iso.wait(lambda: surface(repo, name), f"the question {name}")

    def result(timeout=30):
        iso.wait(lambda: (d / "rc").exists(), f"the router's question {name} to return", timeout)
        return int((d / "rc").read_text()), (d / "out").read_text().strip(), (d / "err").read_text()

    def err():
        return (d / "err").read_text() if (d / "err").exists() else ""
    return result, err


def repo(name):
    path = iso.tmp / "src" / name
    path.mkdir(parents=True)
    git("init", "-q", str(path))
    git("-C", str(path), "remote", "add", "origin", f"git@github.com:Acme/{name}.git")
    return path


def host_root_on():
    rc, out, err = run("rootmode", "on", "host")
    found = re.search(r"this host: (\S+),", out)
    assert rc == 0 and found, (rc, out, err)
    return found.group(1)


def socket(address):
    key, agent = address.rsplit("/", 1)
    return Path(iso.lua("return require('isovim.acp').socket(...)", key, agent))


try:
    iso.start()
    lab, app, tools = repo("lab"), repo("app"), repo("root-tools")

    print("# 6. the iso root file's root holds the place")
    W = run("spawn", "--repo", str(lab), "--name", "w")[1]
    Y = run("spawn", "--repo", str(lab), "--name", "y")[1]
    check([W, Y] == ["acme/lab/a0", "acme/lab/a1"], "two ACP workers", (W, Y))
    run("root", W)
    check(run("root")[1] == "pilothost:" + W, "iso root names W")
    res = inside(Y, "worker promote root")
    check(res[0][0] != 0 and "named by iso root" in res[0][2] and "iso rootmode on host" in res[0][2],
          "a worker can't promote itself over it", res[0])
    check(record(Y)["role"] == "worker", "Y stays a worker", record(Y))
    r = run("role", Y, "root")
    check(r[0] != 0 and "named by iso root" in r[2], "iso role refuses a second root", r)
    r = run("spawn", "--repo", str(lab), "--role", "root", "--name", "r2")
    check(r[0] != 0 and "named by iso root" in r[2], "so does iso spawn --role root", r)
    HR = host_root_on()
    check(record(HR)["role"] == "root" and run("root")[1] == "pilothost:" + HR, "iso rootmode on host takes it over", HR)
    told = iso.wait(lambda: [p for p in prompts(W) if "The user turned root mode on for this host" in p], "W told", 20)
    check(told and HR in told[0], "the old root is told who holds it now", told)
    r = run("role", Y, "root")
    check(r[0] != 0 and "already has a root: " + HR in r[2], "iso role refuses a second root-role holder", r)
    r = run("role", Y, "router")
    check(r[0] == 0 and record(Y)["role"] == "router", "iso role still sets a free role", r)
    r = run("role", W, "router")
    check(r[0] != 0 and "already has a router" in r[2], "and refuses a taken one", r)
    run("rm", HR)
    check(run("root")[1] == "pilothost:" + W, "with the holder gone, the file's root counts again", run("root"))
    run("rm", W)
    check(run("root")[1] == "no root", "with the file's root gone too, there's no root", run("root"))
    res = inside(Y, "ask should I?")
    check(res[0][0] == 0 and "Raised to the user" in res[0][1], "and iso ask raises to the user", res[0])
    run("root", "--clear")

    print("\n# 7. a root's waiting questions are routed on")
    RA = run("spawn", "--repo", str(app), "--role", "router", "--name", "lead")[1]
    HR = host_root_on()
    q1, _ = ask(RA, "q1")
    iso.wait(lambda: surface("acme/app", "q1").get("routed") == HR, "q1 at the host root")
    rc, out, err = run("rm", HR)
    check(rc == 0 and "acme/app/q1 goes to the user" in out, "iso rm of the root hands q1 on", (rc, out, err))
    entry = surface("acme/app", "q1")
    check(entry["needs_you"] and not entry.get("routed"), "q1 waits in your Inbox", entry)
    run("answer", "q1", "yes")
    check(q1()[:2] == (0, "yes"), "and your answer returns it", q1())

    HR = host_root_on()
    q2, q2_err = ask(RA, "q2")
    iso.wait(lambda: surface("acme/app", "q2").get("routed") == HR, "q2 at the host root")
    key, agent = HR.rsplit("/", 1)
    iso.lua("require('isovim').remove_agent(...)", key, agent)
    check(surface("acme/app", "q2")["needs_you"], "with the root removed from the TUI, the Inbox counts q2 at once")
    iso.wait(lambda: not surface("acme/app", "q2").get("routed"), "the router to route q2 on", 20)
    check("is gone; it went to the user" in q2_err(), "the waiting router routed it on itself", q2_err())
    run("answer", "q2", "no")
    check(q2()[:2] == (0, "no"), "your answer returns it", q2())

    HR = host_root_on()
    rc, out, err = run("rootmode", "on", "acme/app")
    RR = re.search(r"acme/app: (\S+),", out).group(1)
    check(rc == 0 and record(RR)["role"] == "repo-root", "a repo root for acme/app", (rc, out, err))
    iso.wait(lambda: socket(RR).exists() and socket(HR).exists(), "both roots' supervisors")
    socket(RR).rename(str(socket(RR)) + ".away")
    q3, q3_err = ask(RA, "q3")
    iso.wait(lambda: surface("acme/app", "q3").get("routed") == HR, "q3 at the host root")
    check(f"could not go to the root {RR}" in q3_err(), "a failed send to the repo root is passed over", q3_err())
    check(not any("acme/app/q3" in p for p in prompts(RR)) and
          iso.wait(lambda: any("[question acme/app/q3" in p for p in prompts(HR)), "q3 to the host root"),
          "q3 goes to the host root instead")
    res = inside(HR, "root answer acme/app/q3 no")
    check(res[0][0] == 0 and q3()[:2] == (0, "no"), "the host root answers q3", (res[0], q3()))
    socket(HR).rename(str(socket(HR)) + ".away")
    q4, q4_err = ask(RA, "q4")
    iso.wait(lambda: q4_err().count("could not go to the root") == 2, "both sends to fail")
    entry = surface("acme/app", "q4")
    check(entry["needs_you"] and not entry.get("routed"), "with every send failed, q4 isn't marked routed: it's yours", entry)
    for root in (RR, HR):
        Path(str(socket(root)) + ".away").rename(socket(root))
    run("answer", "q4", "yes")
    check(q4()[:2] == (0, "yes"), "and your answer returns it", q4())
    run("rootmode", "off", "acme/app")
    run("rootmode", "off", "host")

    print("\n# 8. stamps from an address with root in it; iso answer from a terminal")
    T = run("spawn", "--repo", str(tools), "--name", "t")[1]
    check(T == "acme/root-tools/a0", "a worker in acme/root-tools", T)
    inside(T, f"worker msg {Y} hello-from-tools")
    got = iso.wait(lambda: next((p for p in prompts(Y) if "hello-from-tools" in p), None), "the message")
    verdict = iso.lua("local root = require('isovim.root') local tag = root.tags(...)[1]"
                      " local ok, why = root.check(tag, { select(2, ...) }) return { tag.root, ok, why }", got, Y)
    check(verdict[0] is False and verdict[1] is True, "the stamp verifies, and doesn't claim root", (got[:80], verdict))
    q5, _ = ask(RA, "q5")
    term = run("agent", "acme/lab", "terminal", "--v2", "--name", "sh")
    check(term[0] == 0, "a terminal in acme/lab", term)
    tws, tid = term[1].rsplit("/", 1)
    iso.wait(lambda: iso.lua("return require('isovim.panes').running(...)", tws, tid), "the terminal's shell")
    time.sleep(1)
    out_file = iso.tmp / "term-answer"
    iso.lua("return require('isovim.panes').send(...).code", tws, tid, f"{BIN} answer q5 yes > {out_file} 2>&1; echo $? >> {out_file}")
    iso.wait(lambda: out_file.exists() and out_file.read_text().strip().endswith("0"), "iso answer in the terminal", 20)
    check(q5()[:2] == (0, "yes"), "iso answer from isovim's terminal is the user's", (out_file.read_text(), q5()))

    print("\n# 9. journal lines over 64 KiB")
    big = "x" * 300000
    stats = iso.lua("""
      local journal = require('isovim.acp.journal')
      local big = ...
      local path = journal.path('acme/lab', 'zz')
      vim.fn.mkdir(journal.dir('acme/lab'), 'p')
      local file = assert(io.open(path, 'w'))
      for seq = 1, 5 do file:write(vim.json.encode({ seq = seq, ts = 0, kind = 'notice', text = 'n' }), '\\n') end
      file:write(vim.json.encode({ seq = 6, ts = 0, kind = 'update', update = { text = big } }), '\\n')
      file:close()
      local writer = journal.writer('acme/lab', 'zz')
      local resumed = writer.seq
      writer.append('notice', { text = 'after' })
      local seqs, t = {}, vim.uv.hrtime()
      local stop = journal.follow('acme/lab', 'zz', function(entry) seqs[#seqs + 1] = entry.seq end)
      stop()
      return { resumed = resumed, seqs = seqs, ms = (vim.uv.hrtime() - t) / 1e6 }
    """, big)
    check(stats["resumed"] == 6, "a writer after a restart carries on from seq 6, past a 300 KB last line", stats["resumed"])
    check(stats["seqs"] == [1, 2, 3, 4, 5, 6, 7], "the follower reads every entry, the big one too", stats["seqs"])
    check(stats["ms"] < 2000, "without freezing", stats["ms"])

    print("\n# prompts/ syncs")
    (iso.tmp / "ssh-env").write_text("")
    env = dict(iso.env, ISOVIM_PEERS="peer=peerhost", ISOVIM_SSH=str(REPO / "pilot" / "fake-ssh"),
               FAKE_SSH_ENV=str(iso.tmp / "ssh-env"))
    ours, theirs = HOME / "prompts" / "extra.md", iso.tmp / "peer-home" / "prompts" / "extra.md"
    ours.parent.mkdir(parents=True, exist_ok=True)
    ours.write_text("ours\n")
    r = run("sync", env=env)
    check(r[0] == 0 and theirs.exists() and theirs.read_text() == "ours\n", "a prompt is sent to the peer", (r, theirs.exists()))
    theirs.write_text("theirs, newer\n")
    os.utime(theirs, (time.time() + 60, time.time() + 60))
    ours.write_text("ours, older\n")
    os.utime(ours, (time.time() - 3600, time.time() - 3600))
    run("sync", env=env)
    check(theirs.read_text() == "theirs, newer\n", "never over a newer file there", theirs.read_text())
finally:
    iso.stop()

print("\nfailures:", len(fails))
for f in fails:
    print("  " + f)
sys.exit(1 if fails else 0)
