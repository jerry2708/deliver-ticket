#!/bin/bash
# deliver-ticket hook: guard (mode "guard"). See hooks/lib.sh for the no-state no-op.
. "$(dirname "$0")/lib.sh"
dt_init || exit 0
dt_core guard
exit 0
