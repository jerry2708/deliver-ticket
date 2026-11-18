#!/bin/bash
# See scripts/lock_trace.py. Read-only stage 8 trace of the plan lock: runs inside the sandbox (SANDBOXED in install_hooks.py, allow rule only, never excluded).
exec python3 -I "$(dirname "$0")/lock_trace.py" "$@"
