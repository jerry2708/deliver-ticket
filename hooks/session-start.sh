#!/bin/bash
# deliver-ticket hook: session-start (mode "session"). See hooks/lib.sh for the no-state no-op.
. "$(dirname "$0")/lib.sh"
dt_init || exit 0
dt_core session
exit 0
