#!/bin/bash
# Freshness of <state>/project.md sections, git as the clock. Writes only the project.md you pass in.
#   project-map-stale.sh check        <project.md> --guard <guard.json>   # read-only; prints fresh/stale per section
#   project-map-stale.sh apply        <project.md> --guard <guard.json>   # fresh -> `checked:` advanced to the base ref; stale -> `stale: yes (reason)`
#   project-map-stale.sh mark-checked <project.md> --guard <guard.json> "<section>" ...   # after a rescan of those sections
# (--repo <dir> --ref <ref> instead of --guard for tests.) Exit 0 = all fresh, 1 = something stale or init re-run proposed, 2 = error.
exec python3 -I "$(dirname "$0")/project_map_stale.py" "$@"
