# Agent Instructions

This project uses **bd** (beads) for issue tracking. Run `bd onboard` to get started.

## Before Starting Work (MANDATORY)

ALWAYS run these steps before writing any code:

1. **Check for work:** `bd ready` — find available issues
2. **Claim work:** `bd update <id> --status in_progress` — claim the issue you're working on
3. **If no issue exists** for the task, create one with `bd create`

You MUST have an active bd issue before starting implementation. No exceptions.

## During Work

- Use `bd show <id>` to review issue details
- If you discover sub-tasks or follow-up work, file new issues with `bd create`
- When blocked, note it on the issue

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
   git pull --rebase
   bd sync
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

