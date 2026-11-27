#!/bin/bash -p
# See scripts/ticket_ctl.py (usage in its docstring). Only writers of the session map and of ticket closure besides the hooks.
. "${0%/*}/fixed-env.sh" || exit 2      # C11e3: python3 from a fixed list, only the listed variables (scripts/fixed_env.py)
exec /usr/bin/env -i "${DT_ENV[@]}" "$DT_PY" -I "${0%/*}/ticket_ctl.py" ticket-state "$@"
