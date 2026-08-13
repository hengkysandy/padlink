# Ad-hoc task workspace

This directory is a self-contained **named conversation**, and it is now a hybrid: an
ongoing journal plus a real Swift codebase. `NOTES.md` stays the running journal, kept
exactly as before, terse dated entries recording commands, findings, and decisions.
`Padlink/` is a real codebase with its own package (`PadlinkCore`) and tests, and
`docs/superpowers/` holds the design spec and implementation plans. The goal is durable
continuity across sessions, days, and weeks, for both the journal and the code.

**Running the tests.** From the `Padlink` directory:

```
swift test
```

`xcode-select` was switched to `/Applications/Xcode.app` on 2026-08-13, so this works
directly. If it ever fails with `no such module 'Testing'`, `xcode-select` has been
pointed back at the Command Line Tools, which do not ship `swift-testing`. Fix it with
`sudo xcode-select -s /Applications/Xcode.app`, or override for one command with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.

## On every session start (automatic behavior)

Before doing anything else:

1. **If `NOTES.md` exists:** read it, then summarize the state in 3–5 bullets under a heading **"Where we left off:"** — current task, last finding, open TODOs.
2. **If `NOTES.md` does not exist:** ask the user what task we're starting. Once they answer, create `NOTES.md` with a `# <task-name>` header and an empty `## TODO when resuming` section.
3. After orienting, ask the user what they want to do next — don't auto-execute anything.

## During the session (continuous)

- After every meaningful step (AWS command run, finding, decision, dead-end, hypothesis tested), append to `NOTES.md`.
- Entry format: `## YYYY-MM-DD — <short title>` followed by what happened.
- Keep entries terse — bullet points beat paragraphs. Include the actual command + a one-line summary of its output.
- Save raw outputs (large JSON dumps, log excerpts) as separate files in this directory. Reference them from `NOTES.md` rather than inlining.
- **Never log secrets, full account IDs, or PII** into `NOTES.md`. Mask account IDs as `<account>` if needed.

## On wrap-up (when user says "wrap up", "I'm done", "let's stop", etc.)

- Ensure `NOTES.md` reflects everything we did this session.
- Update the `## TODO when resuming` section at the top so the next session picks up cleanly.
- Briefly tell the user the resume-from state in one or two sentences.

## Scope discipline (important)

- Don't create files outside this directory unless the user asks.
- **Don't run destructive commands without explicit confirmation** — deletes, `terraform destroy`, scaling to zero, IAM changes, security-group widening.
- Use pragmatic judgment — this is ad-hoc debugging, not a project repo. Ask before suggesting heavy patterns.
