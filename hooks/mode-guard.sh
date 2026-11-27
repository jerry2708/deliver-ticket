#!/bin/bash
# deliver-ticket hook: mode-guard (mode "pmode", PreToolUse matcher "*" = every tool). A session bound to an open ticket runs only in default mode (C11h):
# in any other permission mode, or with no permission_mode in the payload, every tool call of that session is blocked (hooks/dtcore.py mode_pmode).
# See hooks/lib.sh for the no-state no-op (no delivery state: no session can be bound).
. "$(dirname "$0")/lib.sh"
dt_init || exit 0
dt_core pmode
exit 0
