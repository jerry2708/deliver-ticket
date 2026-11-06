#!/bin/bash
# deliver-ticket hook: bind-session (mode "bind", UserPromptSubmit). Registered per project (settings.local.json), not at user level.
# `/deliver-ticket <ID> ...` binds this session to <ID> so the full guard applies to it; see hooks/dtcore.py mode_bind.
# Cheap exit first: only prompts that start with the slash command reach python.
. "$(dirname "$0")/lib.sh"
dt_init || exit 0
case "$PAYLOAD" in *'/deliver-ticket'*) ;; *) exit 0 ;; esac
# fail-open on purpose: exit 2 from a UserPromptSubmit hook would erase the user's prompt, and a missed bind only means
# the session keeps Claude Code's normal behaviour (stage 0 reports it with session-map.sh show).
printf '%s' "$PAYLOAD" | DT_STATE_DIR=$DT_STATE DT_HOME=$DT_HOME python3 -I "$DT_DIR/dtcore.py" bind >/dev/null 2>&1
exit 0
