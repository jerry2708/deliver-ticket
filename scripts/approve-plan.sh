#!/bin/bash
# See scripts/approve_plan.py. The gate action that writes <state>/approvals/<ID>.plan: excluded from the sandbox, with a permission ask rule on this path (the user's yes).
exec python3 -I "$(dirname "$0")/approve_plan.py" "$@"
