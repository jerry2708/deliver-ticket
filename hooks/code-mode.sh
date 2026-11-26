#!/bin/bash
# deliver-ticket hook, PreToolUse matcher "REPL" (Code Mode's code tool): Code Mode is not supported, every REPL call is denied.
# The message comes from hooks/dtcore.py (CODE_MODE_MSG); exit 2 whatever happens (fail-closed).
python3 -I "$(dirname "$0")/dtcore.py" codemode || true
exit 2
