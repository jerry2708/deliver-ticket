#!/bin/bash
# scripts/probe-sandbox.sh against a FAKE `claude` (a python script in the scratch dir): the case table, the verdict logic, the exit codes and the argument
# checks work, so the probe cannot silently rot. No real session, no network, nothing outside the scratch dir. Usage: tests/run-probe-sandbox.sh <new scratch dir>
set -u
S=${1:?scratch dir (must be empty or new)}
SK=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$S" && S=$(cd "$S" && pwd -P)
[ -z "$(ls -A "$S")" ] || { echo "scratch dir not empty" >&2; exit 2; }
pass=0; fail=0
eq() { [ "$1" = "$2" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $3: got [$1] want [$2]"; }; }
has() { printf '%s' "$1" | grep -q -- "$2" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $3: missing [$2] in: $(printf '%s' "$1" | head -c 300)"; }; }
PS="$SK/scripts/probe-sandbox.sh"
cat > "$S/fake-claude" <<'PY'
#!/usr/bin/env python3
# fake claude: reads FAKE_TABLE (the probe's --dump-cases), answers the asked command the way the design expects; FAKE_FLIP / FAKE_REWRITE / FAKE_SKIP = case id to break
import json, os, sys
a = sys.argv[1:]
if "--version" in a:
    print("9.9.9 (Claude Code, fake)"); sys.exit(0)
prompt = a[a.index("-p") + 1]
mode = a[a.index("--permission-mode") + 1]
asked = prompt.split("path): ", 1)[1]
# the table was dumped with other scratch / outside dirs than this run uses: map the run's paths onto the table's, and back for the side effects
to_t = lambda s: s.replace(os.environ["FAKE_RUN_OUT"], os.environ["FAKE_DUMP_OUT"]).replace(os.environ["FAKE_RUN_S"], os.environ["FAKE_DUMP_S"])
to_r = lambda s: s.replace(os.environ["FAKE_DUMP_OUT"], os.environ["FAKE_RUN_OUT"]).replace(os.environ["FAKE_DUMP_S"], os.environ["FAKE_RUN_S"])
import re
key_t = lambda s: re.sub(r"proj-[0-9a-f]{8}", "proj-KEY", s)
sf = os.path.basename(a[a.index("--settings") + 1])                 # settings-<case id>-<mode>.json: the case id (two cases can ask the same command)
cid = re.match(r"settings-(.+)-(?:default|auto)\.json$", sf).group(1)
rows = [r for r in json.load(open(os.environ["FAKE_TABLE"])) if r["id"] == cid and r["mode"] == mode]
r = dict(rows[0])
import glob
runkey = [os.path.basename(x) for x in glob.glob(os.environ["FAKE_RUN_OUT"] + "/state/proj-*")]
runkey = runkey[0] if runkey else "proj-KEY"
cmd = to_r(re.sub(r"proj-[0-9a-f]{8}", runkey, r["cmd"]))
r["cmd"] = cmd
r["disk"] = [(k, to_r(re.sub(r"proj-[0-9a-f]{8}", runkey, p))) for k, p in r["disk"]]
out = lambda o: print(json.dumps(o), flush=True)
out({"type": "system", "subtype": "init", "permissionMode": mode})
if os.environ.get("FAKE_SKIP") == r["id"]:
    out({"type": "result", "subtype": "success"}); sys.exit(0)
shown = cmd + " --rewritten" if os.environ.get("FAKE_REWRITE") == r["id"] else cmd
out({"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Bash", "input": {"command": shown}}]}})
kind = r["expect"]
if os.environ.get("FAKE_FLIP") == r["id"]:
    kind = "ok" if kind != "ok" else "prompt"
extra = r.get("contains") or ""
text = {"ok": (extra or "(Bash completed with no output)"), "prompt": "Claude requested permissions to use Bash, but you haven't granted it yet.",
        "denied": "Permission to use Bash with command x has been denied.", "eperm": "Exit code 1\n(eval):1: operation not permitted: x " + extra,
        "hook": "PreToolUse:Bash hook error: [guard.sh]: deliver-ticket: install-hooks.sh apply changes settings files " + extra,
        "net": "curl: (56) CONNECT tunnel failed, response 403", "refused": "Exit code 2\ngit-safe: " + extra}[kind]
if os.environ.get("FAKE_FLIP") != r["id"]:
    for k, p in r["disk"]:
        if k == "exists" and not os.path.isdir(p):
            os.makedirs(os.path.dirname(p), exist_ok=True); open(p, "a").close()
        if k == "changed":
            open(p, "a").write(" ")
out({"type": "user", "message": {"content": [{"type": "tool_result", "content": text, "is_error": kind != "ok"}]}})
out({"type": "result", "subtype": "success"})
PY
chmod +x "$S/fake-claude"
export PROBE_ALLOW_TMP=1
$PS "$S/d0" --outside "$S/o0" --dump-cases > "$S/table.json"; eq "$?" 0 "dump-cases"
N=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))))" "$S/table.json")
export FAKE_TABLE="$S/table.json"
run() { local n=$1; shift; env "$@" FAKE_RUN_S="$S/r$n" FAKE_RUN_OUT="$S/ro$n" FAKE_DUMP_S="$S/d0" FAKE_DUMP_OUT="$S/o0" $PS "$S/r$n" --outside "$S/ro$n" --claude "$S/fake-claude" > "$S/out$n.txt" 2>&1; echo $?; }
echo "# all as designed: every row PASS, exit 0, the run count is printed first"
eq "$(run 1 X=1)" 0 "clean pass"
has "$(head -1 "$S/out1.txt")" "$N runs" "run count up front"
has "$(head -1 "$S/out1.txt")" "9.9.9" "claude version up front"
eq "$(grep -c '| PASS |' "$S/out1.txt")" "$N" "every row passes"
eq "$(ls "$S/r1/raw" | wc -l | tr -d ' ')" "$N" "one raw file per run"
has "$(cat "$S/r1/raw/auto_allow-default.json")" '"bash_calls"' "raw file holds the calls"
echo "# a design property that breaks: FAIL, exit 1; an informational row that differs: CHANGED, exit 3; a rewritten or skipped call: INCONCLUSIVE, exit 4"
eq "$(run 2 FAKE_FLIP=deny_guard_json)" 1 "flipped design row exits 1"
grep -q '| deny_guard_json | default | FAIL |' "$S/out2.txt" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL row deny_guard_json is not FAIL"; }
has "$(grep '| deny_guard_json |' "$S/out2.txt")" "raw: raw/deny_guard_json-default.json" "a FAIL row names its raw file"
eq "$(run 11 FAKE_FLIP=git_push_script_refuses_options)" 1 "a script that does not refuse is a FAIL"
eq "$(run 3 FAKE_FLIP=no_sandbox_control)" 3 "flipped info row exits 3"
grep -q '| no_sandbox_control | default | CHANGED |' "$S/out3.txt" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL row no_sandbox_control is not CHANGED"; }
eq "$(run 4 FAKE_REWRITE=auto_allow)" 4 "rewritten command exits 4"
grep -q '| auto_allow | default | INCONCLUSIVE | command rewritten' "$S/out4.txt" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL rewritten row"; }
eq "$(run 5 FAKE_SKIP=evidence_writable)" 4 "skipped call exits 4"
eq "$(run 6 FAKE_FLIP=deny_guard_json FAKE_REWRITE=auto_allow)" 1 "FAIL beats INCONCLUSIVE"
echo "# arguments"
env FAKE_RUN_S="$S/r7" FAKE_RUN_OUT="$S/ro7" FAKE_DUMP_S="$S/d0" FAKE_DUMP_OUT="$S/o0" $PS "$S/r7" --outside "$S/ro7" --claude "$S/fake-claude" --only auto_allow,deny_sessions > "$S/out7.txt" 2>&1; eq "$?" 0 "--only"
eq "$(grep -c '| \(PASS\|FAIL\|CHANGED\|INCONCLUSIVE\) |' "$S/out7.txt")" 2 "--only runs two rows"
has "$(head -1 "$S/out7.txt")" "2 runs" "run count follows --only"
$PS "$S/r8" --outside "$S/ro8" --claude "$S/fake-claude" --only nope >/dev/null 2>&1; eq "$?" 2 "unknown case"
env FAKE_RUN_S="$S/r9" FAKE_RUN_OUT="$S/ro9" FAKE_DUMP_S="$S/d0" FAKE_DUMP_OUT="$S/o0" $PS "$S/r9" --outside "$S/ro9" --claude "$S/fake-claude" --only gate_script_asks --modes default > "$S/out9.txt" 2>&1; eq "$(grep -c '| gate_script_asks |' "$S/out9.txt")" 1 "--modes narrows"
mkdir -p "$S/r10" && touch "$S/r10/x"; $PS "$S/r10" --outside "$S/ro10" --claude "$S/fake-claude" >/dev/null 2>&1; eq "$?" 2 "non-empty scratch dir refused"
( unset PROBE_ALLOW_TMP; $PS /tmp/zz-probe-never-created --outside /tmp/zz-probe-out-never-created --claude "$S/fake-claude" >/dev/null 2>&1; echo $? ) > "$S/tmpcheck.txt"; eq "$(cat "$S/tmpcheck.txt")" 2 "--outside under /tmp refused"
[ ! -e /tmp/zz-probe-never-created ] && [ ! -e /tmp/zz-probe-out-never-created ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL the refused runs created /tmp dirs"; }
echo "# the case table covers what the design relies on"
for id in auto_allow rename_key_dir excluded_script_after_cd excluded_chained_to_unlisted settings_local_by_bash localhost_client_with_binding localhost_listen_without_binding \
  git_rename_script_excluded git_push_script_refuses_options gate_script_asks gate_script_no_ask_rule_control gh_unlisted_sandboxed installer_apply_blocked allowwrite_glob_unsupported; do
  grep -q "\"id\": \"$id\"" "$S/table.json" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL case $id missing from the probe"; }
done
echo "pass=$pass fail=$fail"; [ $fail = 0 ]
