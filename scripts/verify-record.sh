#!/bin/bash
# Runs the verify.on_push commands of guard.json in a ticket's worktree (inside the sandbox: this script is NOT excluded) and records the result in
# <state>/evidence/<ID>/verify.json: the HEAD tree, each key's exit code and the sha256 of its command string. The push hook (verify-on-push.sh) only READS that record.
#   verify-record.sh <ID> --guard <state>/guard.json [--timeout <sec>]
# Refuses (rc 2, no record) when the worktree is not clean (untracked files included) or when a command changed tracked files. rc 0 all passed, 1 a command failed, 2 refused.
# With a turbo.json in the worktree the commands run with TURBO_CACHE_DIR=<worktree>/.turbo/cache (C11h: otherwise turbo writes the main checkout's cache, EPERM).
# The record is tamper-evident, not tamper-proof: evidence/ is writable from the sandbox (plan.md, milestone 1c, #1). The file tools are blocked on it by the hooks
# (C11h; no Edit deny rule: Claude Code merges Edit deny rules into the sandbox, which then refused this script's own write), a sandboxed Bash write is not;
# stage 8 lock-trace.sh lists every call naming verify.json that is not a plain verify-record.sh call.
exec python3 -I "$(dirname "$0")/verify_record.py" "$@"
