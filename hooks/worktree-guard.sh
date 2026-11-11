#!/bin/bash
# deliver-ticket hook: worktree-guard (mode "wguard"). See hooks/lib.sh for the no-state no-op.
. "$(dirname "$0")/lib.sh"
dt_init || { dt_nostate; exit 0; }
dt_core wguard
exit 0
