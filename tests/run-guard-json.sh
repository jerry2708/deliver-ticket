#!/bin/bash
# valid.json must pass (exit 0); bad-notjson.json must exit 2; every other bad-*.json must exit 1
cd "$(dirname "$0")/.." || exit 1
[ "$(cd "." && pwd -P)" = "$(cd "$HOME/.claude/skills/deliver-ticket" 2>/dev/null && pwd -P)" ] && echo "warning: this suite tests the LIVE checkout $(pwd -P) - build and test in the dev clone (docs/plan.md, dev-copy process)" >&2
fail=0
for f in tests/guard-json/*.json; do
  scripts/validate-guard.py "$f" >/dev/null 2>&1; rc=$?
  case "$(basename "$f")" in
    valid.json) want=0 ;;
    bad-notjson.json) want=2 ;;
    *) want=1 ;;
  esac
  if [ "$rc" = "$want" ]; then echo "ok   $(basename "$f") (exit $rc)"; else echo "FAIL $(basename "$f"): exit $rc, want $want"; fail=1; fi
done
exit $fail
