---
name: orchestrate
description: Split a task across agents in icarus: spawning, merging or retiring agents, wiring edges and topologies, and choosing between router-worker and democracy. Use when work is bigger than one agent, when an agent needs another agent's help, or when the task's organization is being set up or changed.
---

# Orchestrating agents in icarus

Two organizations are allowed for now: router-worker and democracy. The task's `orchestration.md` says how each works, and the reviews edges in it are the reason a claim reaches the user.

## Router-worker

- One lead talks to the user. Workers do one job each and report to the lead with `ica msg <lead> <message>`.
- The lead spawns a worker for each real job: `ica spawn <job>`. Light jobs it does itself.
- Specialties for `ica spawn`: slack-watcher, eval-runner, skeptic, historian, decision-keeper, blast-radius, simplifier.
- A worker that finishes its job says so and waits. The lead decides what's next.

## Democracy

- Peers, no lead. Each node holds one claim: `ica claim <what>`. A claim with no edge to a reviewer must be marked `--trivial`.
- Wire edges with `ica edge reviews|needs|contests|talks <agent>`, and remove them with `ica unedge`. Talk only along edges.
- Topologies: `ica topology ring|debate|mesh`. Ring: each reviews the next. Debate: two contest, a third reviews both. Mesh (up to four): everyone reviews everyone.
- Decisions that touch other agents: `ica propose-to-peers <what>`. Each must answer `ica vote agree <id>` or `ica vote object <id> <why>`. Silence never counts.

## Moves that apply to both

- `ica merge <agent>` is a bid: the caller says it's the parent. The child agrees with `ica merge --accept <agent> <handoff>` and ends, or declines with `ica merge --decline <agent> <why>`.
- `ica retire` when your claim has landed and nothing related is next.

## Invariants icarus enforces

- Every claim reaches the user through a reviews edge, or is marked trivial.
- No deadlocks: a wait that would close a cycle is refused, and the agent who joined last must talk it out.
- Caps: six nodes per task and three edges per node by default. Over the cap, merge or retire first.
- One claim per node.

## Judgment

- Split only when the work has separate parts. A job one agent can do in one sitting stays with that agent.
- Name each agent with `ica name` once its job is clear, so the user can tell them apart.
- Don't add a worker to fix a problem a message would solve.
