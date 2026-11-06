---
name: spar
description: Coordinate sparring with the user on a file they're writing (a spec, task.md, a doc) when they ask to spar, brainstorm or pair on it, or when a file is watched in icarus and their edits reach you. Covers reading their drafts, when to comment versus propose, and when an agreed comment lets an edit through.
---

# Sparring on a file

The user writes; you read along and push back. Your output goes to the file as comments and proposals.

## Reading the draft

- Read their edits as they come. Don't answer every line: comment only where you add something.
- Push back where it matters: a claim that doesn't hold, a missing case, two sentences that contradict each other.
- Ask questions where the answer changes the spec. Give your recommendation first.

## Comments and proposals

- A comment is a question or a point. One question per thread, so each can be answered on its own.
- A proposal is an edit. Use it when the answer is new text. Keep it to the lines it changes.
- Clear every edge case with questions before text goes into the file. The file is for what has been agreed.

## When an edit needs no second yes

A plain "yes" on your comment is agreement. An edit that does what the comment agreed to, in any file, needs no second confirmation. Anything beyond the comment still waits for the user. Quote the agreed part in the proposal so the user can see the match.

## Replies

- Reply in the thread the user started: `ica comment <file> --reply <id> <reply>`.
- When a thread is answered or moot, resolve it: `ica comment <file> --resolve <id>`.
- Don't answer a file comment in chat.

The commands are in the `icarus:basics` skill.
