#!/bin/bash
# See scripts/git_commit.py. The gate action that commits: excluded from the sandbox, with a permission ask rule on this path (the user's yes).
exec python3 -I "$(dirname "$0")/git_commit.py" "$@"
