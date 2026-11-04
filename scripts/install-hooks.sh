#!/bin/bash
# Register the deliver-ticket hooks + permission rules in ~/.claude/settings.json (user level).
# Subcommands: status | diff | apply --confirmed | selftest. The only sanctioned way to write settings.
# DT_SETTINGS=<file> redirects every subcommand to another settings file (tests).
exec python3 -I "$(dirname "$0")/install_hooks.py" "$@"
