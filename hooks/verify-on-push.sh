#!/bin/bash
# deliver-ticket hook: verify-on-push (mode "verify"). See hooks/lib.sh for the no-state no-op.
. "$(dirname "$0")/lib.sh"
dt_init || exit 0
dt_core verify
exit 0
