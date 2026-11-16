#!/bin/bash
# Runs the verify.on_push commands of guard.json in a ticket's worktree (inside the sandbox: this script is NOT excluded) and records the result in
# <state>/evidence/<ID>/verify.json: the HEAD tree, each key's exit code and the sha256 of its command string. The push hook (verify-on-push.sh) only READS that record.
#   verify-record.sh <ID> --guard <state>/guard.json [--timeout <sec>]
# Refuses (rc 2, no record) when the worktree is not clean (untracked files included) or when a command changed tracked files. rc 0 all passed, 1 a command failed, 2 refused.
# The record is tamper-evident, not tamper-proof: evidence/ is writable from the sandbox (plan.md, milestone 1c, #1).
exec python3 -I "$(dirname "$0")/verify_record.py" "$@"
