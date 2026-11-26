# Changelog

One generic line per applied lesson or rule change. Newest first.

- 0.2.0-dev (`v0.1.0..v0.2-dev`, up to 2026-11-18): hardening of the guard and the plan gate.
  - Hooks: protected state checked in every repo and cwd; paths and program names compared case-insensitively; gated commands only in the spelling their ask rule matches; `guard.json` written only through `guard-write.sh` / the `guard-apply.sh` gate; symlinks and directory-level copies into the state blocked; a binding to another project never clears one that still holds.
  - Sandbox: user-level settings (no unsandboxed retry, protected state not writable) and a per-project Bash sandbox; only enumerated `gh` / `glab` forms excluded; Claude never runs the installer's writing subcommands; `probe-sandbox.sh` and the TUI dry-run checklist re-check the design per Claude Code version.
  - Push and rename: `git-push.sh` (gate) / `git-rename.sh` run git with the repo's hooks off; plain `git push` / `git branch -m` blocked; the push hook checks a sandboxed verify record (`verify-record.sh`) instead of running commands; the user's git config protected.
  - Plan lock: writes under an open ticket's worktree blocked until `approve-plan.sh` records the hash of the plan shown with `plan-hash.sh`; `approvals/` protected; settings files, the skill dir (exempt only for a session started in the skill repo, `session-record.sh`) and ssh / gh / glab config protected in every session; stage 8 `lock-trace.sh` reports what the lock does not stop.
  - Permission mode: ticket sessions run in default mode; auto mode is no longer supported (the hook blocks the Bash per-call parameters `allowed_domains` and `dangerouslyDisableSandbox`, but auto mode may approve other things).
  - Commits (C11e2): `git-commit.sh` logs the commit's own tree and file list (renames as delete + add) and exits 3 with a `MISMATCH` line when the commit is not what was staged; stage 7 shows `git diff --cached --stat=10000 --no-renames` right before it, and stage 8 `lock-trace.sh` compares that stat, the log line and the repo per commit (a trace, not proof).
  - Build process: a dev clone for building the skill; every test suite warns when it runs against the live checkout.
- 0.1.0-dev: skeleton and SKILL.md (phase 1).
