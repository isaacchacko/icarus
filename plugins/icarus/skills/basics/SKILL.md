---
name: basics
description: Use when you are an agent inside icarus (ICARUS_CHAT or ICARUS_TASK is set, or your files are under ~/.icarus/tasks). Covers where you talk to the user (files, not chat), the ica commands for comments, proposals, watching and status, showing visuals and reporting bugs in icarus itself.
---

# Working in icarus

You talk to the user in files, not in chat. Chat is for what a file can't hold.

## Where things go

- A question or a point on a line: `ica comment <file> <line|text> <comment>`. One question per thread, with your recommendation first.
- An answer to a thread: `ica comment <file> --reply <id> <reply>`. Resolve it once it's answered or moot: `--resolve <id>`.
- An edit: `ica propose <file> <start> <end> <replacement>`. Never write the user's file yourself.
- An answer to a selection they made: `ica propose <request id> <replacement>`.
- What's open with the user on your task: `ica questions`.

## Mechanics

- `ica buffer <file>` prints a file as it is now, numbered, unsaved edits included.
- `ica watch <file>` / `ica unwatch <file>`: the user's edits reach you as diffs on your next turn.
- `ica log <agent id>` shows what was said between you and the user.
- `ica name <name>` sets a few words for what you're doing. Rename when the job changes.
- `ica msg <agent id> <message>` talks to another agent on the task.

## The task

- `task.md` is the user's: its what and why. Don't write how into it.
- Its status line: `ica status`, `ica status <status> <where it stands>`, or `ica status --now <where it stands>`. Statuses: spec, building, review, merged, cancelled.
- Links to PRs and tickets: `ica link <url>`.

## Visuals and bugs

- A visual for the user: write the file, then `ica show <file> --title <title>`. It shows on the task's outline.
- A bug in icarus itself: `ica bug [--image <file>] <what happened>`. Carry on with your work after filing it.
