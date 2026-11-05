#!/bin/bash
# Register the deliver-ticket hooks + permission rules in ~/.claude/settings.json (user level).
# Subcommands: status | diff | apply --confirmed | uninstall | selftest [--repo R] | project-status|project-diff|project-apply|project-uninstall --repo R (WorktreeCreate, per project). The only sanctioned way to write settings.
# DT_SETTINGS=<file> redirects every subcommand to another settings file (tests).
exec python3 -I "$(dirname "$0")/install_hooks.py" "$@"
