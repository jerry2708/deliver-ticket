#!/bin/bash
# See scripts/guard_write.py (usage in its docstring). The only writer of <state>/guard.json; the hooks block every other route.
exec python3 -I "$(dirname "$0")/guard_write.py" "$@"
