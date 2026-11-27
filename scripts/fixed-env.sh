# Sourced by every script excluded from the sandbox (gates + bookkeeping, install_hooks.GATES / BOOKKEEPING) right after `#!/bin/bash -p`
# (-p: BASH_ENV is not read and exported functions are not imported - an exported `exec` replaced the wrapper's exec under plain #!/bin/bash).
# Sets DT_PY (python3 from a fixed list, never PATH) and DT_ENV (the only variables the wrapper passes through `/usr/bin/env -i`). Uses builtins
# and absolute paths only. The why of each variable and candidate: scripts/fixed_env.py (C11e3); the two candidate lists are kept equal by a test.
DT_PY=
for _p in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
  if [ -f "$_p" ] && [ -x "$_p" ]; then DT_PY=$_p; break; fi
done
[ -n "$DT_PY" ] || { echo "deliver-ticket: no python3 at /opt/homebrew/bin, /usr/local/bin or /usr/bin (fixed list, scripts/fixed_env.py)" >&2; exit 2; }
_u=$(/usr/bin/id -un)
case $_u in ''|*[!A-Za-z0-9._-]*) echo "deliver-ticket: unexpected user name '$_u'" >&2; exit 2;; esac
eval "DT_PWHOME=~$_u"          # ~name: the password database, not $HOME
DT_ENV=(PATH=/usr/bin:/bin:/usr/sbin:/sbin "HOME=$DT_PWHOME")
for _v in $(compgen -e); do
  case $_v in SSH_AUTH_SOCK|LANG|DELIVER_TICKET_HOME|LC_*) DT_ENV+=("$_v=${!_v}");; esac
done
