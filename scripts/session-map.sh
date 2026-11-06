#!/bin/bash
# See scripts/ticket_ctl.py (usage in its docstring). Only writers of the session map and of ticket closure besides the hooks.
exec python3 -I "$(dirname "$0")/ticket_ctl.py" session-map "$@"
