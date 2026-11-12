#!/bin/bash
# See scripts/guard_apply.py. The gate action that writes <state>/guard.json: excluded from the sandbox, with a permission ask rule on this path.
exec python3 -I "$(dirname "$0")/guard_apply.py" "$@"
