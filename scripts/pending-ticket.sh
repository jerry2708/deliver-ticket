#!/bin/bash -p
# Keep the input of a ticket that was started before the project was initialised, so init can run and the ticket
# then continues at stage 0 without the user pasting it again.
#   pending-ticket.sh save <ID> --repo <repo>   # raw ticket input on stdin -> <state>/pending/<ID>.md (refuses to overwrite)
#   pending-ticket.sh take <ID> --repo <repo>   # prints it and renames the file to <ID>.md.consumed (nothing is deleted)
#   pending-ticket.sh list --repo <repo>        # pending IDs
# <state> = ~/.local/share/deliver-ticket/<project-key>/ (DELIVER_TICKET_HOME overrides the root). A state dir without
# guard.json is "not initialised" for the hooks, so saving here changes no hook behaviour.
. "${0%/*}/fixed-env.sh" || exit 2      # C11e3: PATH and HOME fixed, only the listed variables (scripts/fixed_env.py); the body is pending_ticket_run.sh
exec /usr/bin/env -i "${DT_ENV[@]}" /bin/bash -p "${0%/*}/pending_ticket_run.sh" "$@"
