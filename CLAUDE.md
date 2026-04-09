# Agent Instructions

This project uses **bd** (beads) for issue tracking. Run `bd onboard` to get started.

## Fresh Clone Setup

After cloning the repo, set up beads before doing anything else:

```bash
chmod 700 .beads
bd bootstrap
bd import
bd hooks install
git config beads.role maintainer
```

This creates the local Dolt database and loads issues from the git-tracked `.beads/issues.jsonl`.

## Before Starting Work (MANDATORY)

ALWAYS run these steps before writing any code:

1. **Check for work:** `bd ready` — find available issues
2. **Claim work:** `bd update <id> --status in_progress` — claim the issue you're working on
3. **If no issue exists** for the task, create one with `bd create`

You MUST have an active bd issue before starting implementation. No exceptions.

## Planning (MANDATORY for multi-step work)

When a task involves multiple steps, files, or components, you MUST structure it in bd before writing code:

1. **Every phase gets an epic:**
   ```bash
   bd create "Phase N: Title" --type epic --priority 1 --description "Overview"
   ```
2. **Every step in the phase gets a child issue:**
   ```bash
   bd create "Sub-task title" --type task --parent <epic-id> --description "Details"
   ```
3. **Set dependencies** — between children when order matters, between epics when phases depend on each other:
   ```bash
   bd dep add <blocked-id> <blocker-id>
   ```
4. **Work the children in order** — claim, implement, close each one before moving to the next.

A plan without bd issues is just a comment. The epic and its children ARE the plan. No phase exists without an epic.

## During Work

- Use `bd show <id>` to review issue details
- If you discover sub-tasks or follow-up work, file new issues with `bd create --parent <epic-id>`
- When blocked, note it on the issue
- Use `bd epic status` to check progress on the current epic

## Building

After a successful build, always install and launch in the simulator to verify:

```bash
xcodebuild -scheme AdagioStream -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null; xcrun simctl install "iPhone 17 Pro" ~/Library/Developer/Xcode/DerivedData/AdagioStream-*/Build/Products/Debug-iphonesimulator/AdagioStream.app && xcrun simctl launch "iPhone 17 Pro" com.adagiostream.app
```

## Testing

Run unit tests after code changes:

```bash
xcodebuild test -scheme AdagioStream -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AdagioStreamTests
```

## Versioning

Bump `CURRENT_PROJECT_VERSION` in `project.yml` when making code changes, then regenerate with `xcodegen generate`.

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** — `bd create` for anything that needs follow-up
2. **Run quality gates** (if code changed) — tests, linters, builds
3. **Close finished issues** — `bd close <id>` for every completed issue
4. **Sync and push** — this is MANDATORY, every step:
   ```bash
   bd export
   git add .beads/issues.jsonl
   git pull --rebase
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** — clear stashes, prune remote branches
6. **Verify** — all changes committed AND pushed, all issues updated
7. **Hand off** — provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing — that leaves work stranded locally
- NEVER say "ready to push when you are" — YOU must push
- If push fails, resolve and retry until it succeeds
- EVERY issue you worked on MUST be closed or updated before session ends

