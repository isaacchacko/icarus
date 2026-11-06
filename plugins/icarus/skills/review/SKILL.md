---
name: review
description: Review work in icarus: finishing your own claim with ica done, approving or rejecting another agent's claim, objecting to a decision, and retiring when your part has landed. Use when you're asked to review, when your work is ready to hand over, or when a reviews edge brings another agent's output to you.
---

# Reviewing in icarus

Review means reading the work against the spec, not just the diff. The spec is the task's `task.md` and any design doc beside it.

## Finishing your own claim

- Run it or test it before you call it done. Check the output, not only that it compiles.
- `ica done`: the claim goes to its reviewers and reaches the user once they approve.
- Say in your last message what you checked and what you didn't.

## Reviewing another agent's claim

- Read the output against the spec. Open the files it touched and check the behavior, not only the diff.
- Approve with `ica approve <agent>` when the claim is good.
- Send it back with `ica reject <agent> <why>`, with the one thing that has to change.
- Questions about the work go to the user as comments in the file, one per thread, not into your reject message.

## Decisions

- Object to a decision with `ica vote object <id> <why>`. An objection sends it back for one revision.
- Agree with `ica vote agree <id>`. Silence doesn't count.
- A decision you took back: `ica withdraw <id>`.

## Retiring

- `ica retire` when your claim has landed and nothing related is next. Your edges go to whoever needed you.
- `ica unclaim` gives up a claim you can't finish. Say why in the task's shared channel with `ica post`.

The organization and the reviews edges are in the `icarus:orchestrate` skill.
