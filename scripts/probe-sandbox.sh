#!/bin/bash
# See scripts/probe_sandbox.py (usage in its docstring). Re-runnable check of the Bash-sandbox design on the installed Claude Code; scratch dir + an outside-/tmp dir only.
exec python3 -I "$(dirname "$0")/probe_sandbox.py" "$@"
