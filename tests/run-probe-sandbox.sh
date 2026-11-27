#!/bin/bash
# scripts/probe-sandbox.sh against a FAKE `claude` (a python script in the scratch dir): the case table, the verdict logic, the exit codes and the argument
# checks work, so the probe cannot silently rot. No real session, no network, nothing outside the scratch dir. Usage: tests/run-probe-sandbox.sh <new scratch dir>
set -u
S=${1:?scratch dir (must be empty or new)}
SK=$(cd "$(dirname "$0")/.." && pwd)
[ "$(cd "$SK" && pwd -P)" = "$(cd "$HOME/.claude/skills/deliver-ticket" 2>/dev/null && pwd -P)" ] && echo "warning: this suite tests the LIVE checkout $SK - build and test in the dev clone (docs/plan.md, dev-copy process)" >&2
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
asked = prompt.split("path): ", 1)[1] if "path): " in prompt else prompt[len("Run exactly: "):-len(" and report output")]     # the default lead-in, or NEUTRAL_PROMPT
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
params = {} if os.environ.get("FAKE_DROPPARAM") == r["id"] else r.get("params", {})
tool = r.get("tool") or "Bash"
inp = {"file_path": shown} if r.get("tool") else dict({"command": shown}, **params)
if tool == "Edit":           # the Read before an Edit: its result must not count
    out({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "r1", "name": "Read", "input": {"file_path": shown}}]}})
    out({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "r1", "content": "Claude requested permissions to read, but you haven't granted it yet."}]}})
out({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "t1", "name": tool, "input": inp}]}})
kind = r["expect"] if isinstance(r["expect"], str) else r["expect"][0]
if os.environ.get("FAKE_FLIP") == r["id"]:
    kind = "ok" if kind != "ok" else "prompt"
extra = r.get("contains") or ""
text = {"ok": (extra or "(Bash completed with no output)"), "prompt": "Claude requested permissions to use Bash, but you haven't granted it yet.",
        "denied": "Permission to use Bash with command x has been denied.", "eperm": "Exit code 1\n(eval):1: operation not permitted: x " + extra,
        "hook": "PreToolUse:Bash hook error: [guard.sh]: deliver-ticket: install-hooks.sh apply changes settings files " + extra,
        "net": "curl: (56) CONNECT tunnel failed, response 403", "refused": "Exit code 2\ngit-safe: " + extra, "error": "Exit code 1\nCannot save the current status",
        "gitrefused": "Exit code 128\nfatal: refusing to fetch into branch 'refs/heads/x' checked out at '/x'"}[kind]
if os.environ.get("FAKE_EXITFAIL") == r["id"]:      # the command failed with a message that names no known verdict: must not read as ok
    text = "Exit code 1\nsomething went wrong"
if os.environ.get("FAKE_FLIP") != r["id"]:
    for k, p in r["disk"]:
        if k == "exists" and not os.path.isdir(p):
            os.makedirs(os.path.dirname(p), exist_ok=True); open(p, "a").close()
        if k == "changed":
            open(p, "a").write(" ")
        if k == "has":
            f, needle = p.split("::", 1); open(f, "a").write(needle + "\n")
if True:      # FAKE_MOVEREF: a commit that went through although the answer looks like a prompt (only the ref check sees it); revmoved: the expected move
    import subprocess
    for k, p in r["disk"]:
        if (k == "rev" and os.environ.get("FAKE_MOVEREF") == r["id"]) or (k == "revmoved" and os.environ.get("FAKE_FLIP") != r["id"]):
            repo, ref = p.split("::")
            g = lambda *x: subprocess.run(["git", "-C", repo] + list(x), capture_output=True, text=True).stdout.strip()
            g("update-ref", ref, g("commit-tree", g("rev-parse", ref + "^{tree}"), "-p", ref, "-m", "fake"))
if r.get("tool") and kind == "denied":        # a file tool's deny answer (2.1.311) has other words than a Bash one
    text = "<tool_use_error>File is in a directory that is denied by your permission settings.</tool_use_error>"
if os.environ.get("FAKE_NOTREAD") == r["id"]:
    text = "<tool_use_error>File has not been read yet. Read it first before writing to it.</tool_use_error>"
out({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t1", "content": text, "is_error": kind != "ok"}]}})
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
echo "# C11d: a call without the asked tool parameter proves nothing (INCONCLUSIVE); the parameter widening the network past the hook (ok) is a FAIL"
eq "$(run 12 FAKE_DROPPARAM=bash_allowed_domains_param)" 4 "dropped parameter exits 4"
has "$(grep '| bash_allowed_domains_param | default |' "$S/out12.txt")" "INCONCLUSIVE | parameter allowed_domains missing" "dropped parameter row"
eq "$(run 13 FAKE_FLIP=bash_allowed_domains_param)" 1 "allowed_domains widening the network is a FAIL"
has "$(grep '| bash_allowed_domains_param | default |' "$S/out13.txt")" "got ok, want hook" "hole row"
has "$(cat "$S/r1/raw/bash_allowed_domains_param-default.json")" '"allowed_domains"' "raw file keeps the tool parameters"
eq "$(run 16 FAKE_FLIP=bash_disable_sandbox_param)" 1 "dangerouslyDisableSandbox past the hook is a FAIL"
has "$(cat "$S/r16/settings-bash_disable_sandbox_param-auto.json")" "$SK/hooks/guard.sh" "hooks=True registers this checkout's guard.sh"
echo "# C11d: the param case is PASS only when its positive control reached example.com in the same run and mode"
eq "$(run 14 FAKE_FLIP=bash_allowed_domains_control)" 1 "control not reaching the site exits 1 (the control row FAILs)"
has "$(grep '| bash_allowed_domains_param | default |' "$S/out14.txt")" "INCONCLUSIVE | hook, but control bash_allowed_domains_control is FAIL in this run" "param row after a failed control"
env FAKE_RUN_S="$S/r15" FAKE_RUN_OUT="$S/ro15" FAKE_DUMP_S="$S/d0" FAKE_DUMP_OUT="$S/o0" $PS "$S/r15" --outside "$S/ro15" --claude "$S/fake-claude" --only bash_allowed_domains_param > "$S/out15.txt" 2>&1
eq "$?" 4 "param case without its control exits 4"
has "$(grep '| bash_allowed_domains_param | auto |' "$S/out15.txt")" "control bash_allowed_domains_control is not run in this run" "param row without its control"
echo "# C11a: file-tool cases count only their own tool's results (the fake's Read before an Edit answers 'not granted'; the clean run above passes anyway)"
eq "$(run 17 FAKE_FLIP=tool_write_verify_json_hook)" 1 "a Write past the verify.json hook is a FAIL"
has "$(grep '| tool_write_verify_json_hook | default |' "$S/out17.txt")" "got ok, want hook" "verify.json hook row"
eq "$(run 18 FAKE_NOTREAD=tool_edit_evidence_allow)" 4 "an Edit refused for 'not read first' proves nothing"
has "$(grep '| tool_edit_evidence_allow | default |' "$S/out18.txt")" "INCONCLUSIVE | Edit refused before the permission check" "not-read row"
eq "$(run 19 FAKE_FLIP=tool_write_no_rule_control)" 1 "a Write without a rule that does not prompt FAILs the control"
has "$(grep '| tool_write_edit_allow_tilde | default |' "$S/out19.txt")" "control tool_write_no_rule_control is FAIL in this run" "allow row after a failed control"
has "$(cat "$S/r1/settings-tool_write_edit_allow_abs-default.json")" "Edit(/$S/ro1/state/\*/evidence/\*\*)" "// spelling of the state root"
has "$(cat "$S/r1/settings-tool_write_edit_allow_tilde-default.json")" "Edit(~/OUTSIDE-NOT-UNDER-HOME/\*/evidence/\*\*)" "~/ spelling needs the outside dir under home"
has "$(cat "$S/r1/settings-tool_edit_delivery_log_denied-default.json")" "Edit(/$S/ro1/state/\*/delivery.log)" "deny rules are the installer's (protected list)"
eq "$(grep -c 'evidence/\*/verify.json' "$S/r1/settings-tool_edit_delivery_log_denied-default.json")" 0 "C11h: no Edit deny on the push record (it became a sandbox denyWrite)"
has "$(cat "$S/r1/settings-verify_record_retired_deny_control-default.json")" "Edit(/$S/ro1/state/\*/evidence/\*/verify.json)" "the control case carries the retired push-record rule"
has "$(cat "$S/r1/settings-verify_record_sandboxed-default.json")" "Edit(/$S/ro1/state/\*/delivery.log)" "verify_record_sandboxed carries the installer's user-level file rules"
has "$(cat "$S/r1/raw/tool_edit_evidence_allow-default.json")" '"tool": "Edit"' "raw file names the tool"
echo "# C11b: the worktree ask rules and the plan lock under the worktree Edit allow"
eq "$(run 20 FAKE_FLIP=hook_wt_locked_write)" 1 "a Write in a locked worktree past the hook is a FAIL"
has "$(grep '| hook_wt_locked_write | default |' "$S/out20.txt")" "got ok, want hook" "locked worktree row"
eq "$(run 21 FAKE_FLIP=tool_wt_mcp_asks)" 1 "a .mcp.json Write without a prompt is a FAIL"
has "$(cat "$S/r1/settings-hook_wt_locked_write-default.json")" "$SK/hooks/worktree-guard.sh" "hooks=True registers the Edit / Write hook too"
has "$(cat "$S/r1/settings-tool_wt_edit_allowed-default.json")" "Edit(/$S/r1/proj/.claude/worktrees/\*\*)" "the worktree allow is project-apply's"
[ -f "$S/ro1/state/$(ls "$S/ro1/state" | grep '^proj-')/approvals/T5.plan" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL the C11b fixture has no approval for T5"; }
echo "# C11c1: autoAllowBashIfSandboxed in every generated sandbox; ask / deny rules and the commit gate are kept (a moved branch ref is a FAIL whatever the answer)"
has "$(cat "$S/r1/settings-auto_allow-default.json")" '"autoAllowBashIfSandboxed": true' "the sandbox plan sets autoAllowBashIfSandboxed"
eq "$(run 22 FAKE_FLIP=autoallow_ask_rule_kept)" 1 "a git commit past the ask rule is a FAIL"
eq "$(run 23 FAKE_FLIP=autoallow_deny_rule_kept)" 1 "an rm -rf past the deny rule is a FAIL"
eq "$(run 24 FAKE_MOVEREF=commit_bypass_cd)" 1 "a moved branch ref is a FAIL even when the answer looks like a prompt"
has "$(grep '| commit_bypass_cd | default |' "$S/out24.txt")" "disk: want rev" "moved-ref row"
eq "$(run 25 FAKE_FLIP=commit_bypass_dir_flag_hooks)" 1 "a git -C commit that runs is a FAIL"
echo "# refs-deny probe: a ref move under the deny is a FAIL; the excluded gate control must move the ref"
eq "$(run 26 FAKE_MOVEREF=refs_write_ref_file)" 1 "a ref file write that lands is a FAIL"
eq "$(run 27 FAKE_FLIP=refs_ctl_gate_commit)" 1 "a gate commit that does not land is a FAIL"
has "$(grep '| refs_ctl_gate_commit | default |' "$S/out27.txt")" "disk: want revmoved" "gate control row"
echo "# C11 commit gate: a commit the gate should make that does not land, or a log line that is missing, is a FAIL"
eq "$(run 29 FAKE_FLIP=gate_late_staged_logged)" 1 "a late-staged file missing from the log is a FAIL"
has "$(grep '| gate_late_staged_logged | default |' "$S/out29.txt")" "disk: want has" "late-staged row"
has "$(cat "$S/r1/settings-gate_commit_ok-default.json")" "Bash($SK/scripts/git-commit.sh \*)" "m_gate allows the gate"
has "$(cat "$S/r1/settings-auto_allow-default.json")" "/.git/refs/\*\*" "the ref-store deny is in every generated sandbox"
has "$(cat "$S/r1/settings-auto_allow-default.json")" "/.git/info/attributes" "C11: the git-read deny is in every generated sandbox"
eq "$(run 33 FAKE_FLIP=gitcfg_write_info_attributes)" 1 "an info/attributes write that lands is a FAIL"
echo "# C11c3: base-worktree.sh must check out _base unsandboxed; the _base install must stay sandboxed"
eq "$(run 30 FAKE_FLIP=base_worktree_excluded)" 1 "an excluded base-worktree.sh that does not run is a FAIL"
eq "$(run 31 FAKE_FLIP=base_setup_sandboxed)" 1 "a _base setup that does not run is a FAIL"
eq "$(run 32 FAKE_FLIP=base_worktree_refuses_ticket_commit)" 1 "a ticket commit checked out into _base is a FAIL"
has "$(cat "$S/r1/settings-base_worktree_excluded-default.json")" "$SK/scripts/base-worktree.sh \*" "base-worktree.sh is excluded in the generated sandbox"
has "$(cat "$S/r1/settings-base_worktree_excluded-default.json")" "/bw-base_worktree_excluded/.claude/worktrees/\*/.claude/settings\*.json" "m_bw adds the bw repo's denyWrite"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(any("base-worktree.sh" in e for e in d["sandbox"]["excludedCommands"] + d["permissions"]["allow"]))' \
  "$S/r1/settings-base_worktree_sandboxed_control-default.json" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL the control still excludes / allows base-worktree.sh"; }
echo "# verdicts use the exit status: a failed command whose message names no known verdict is \`error\`, never ok"
eq "$(run 28 FAKE_EXITFAIL=refs_ctl_add)" 1 "git add that exits 1 is a FAIL"
has "$(grep '| refs_ctl_add | default |' "$S/out28.txt")" "got error, want ok" "exit-status row"
python3 - "$SK/scripts" <<'UNIT' && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL classify unit (exit status)"; }
import os, sys
sys.path.insert(0, sys.argv[1]); os.environ["DT_SETTINGS"] = "/nonexistent"
import probe_sandbox as p
c = p.classify
assert c(["Exit code 1\nCannot save the current status"]) == "error"
assert c(["<tool_use_error>String to replace not found in file.</tool_use_error>"]) == "error"
assert c(["(Bash completed with no output)"]) == "ok" and c(["[work/t5 fc8751d] gate"]) == "ok" and c(["File created successfully at: /x"]) == "ok"
assert c(["Exit code 128\nfatal: cannot lock ref 'HEAD': Unable to create '/r/.git/refs/heads/x.lock': Operation not permitted"]) == "eperm"
assert c(["Exit code 128\nfatal: refusing to fetch into branch 'refs/heads/x' checked out at '/w'"]) == "gitrefused"
assert c(["Exit code 2\ngit-safe: refused"]) == "refused" and c(["output mentions Exit code 0 only"]) == "ok"
UNIT
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
  git_rename_script_excluded git_push_script_refuses_options gate_script_asks gate_script_no_ask_rule_control gh_unlisted_sandboxed installer_apply_blocked allowwrite_glob_unsupported \
  bash_allowed_domains_param bash_allowed_domains_control bash_disable_sandbox_param tool_write_no_rule_control tool_write_edit_allow_tilde tool_write_edit_allow_abs \
  tool_write_rule_of_its_own tool_edit_evidence_allow tool_write_verify_json_hook tool_edit_verify_json_hook verify_record_retired_deny_control tool_read_skill_tilde tool_edit_delivery_log_denied \
  tool_read_skill_no_rule tool_read_skill_installer_rule tool_wt_edit_allowed tool_wt_claude_settings_asks tool_wt_git_pointer_asks tool_wt_base_asks \
  hook_wt_locked_write hook_wt_approved_write_ok hook_approvals_write hook_bash_sed_locked hook_bash_redirect_locked hook_mode_auto_bound hook_mode_default_bound_ok tool_wt_vscode_asks tool_wt_claude_md_root_asks \
  tool_wt_claude_md_nested_asks tool_wt_agents_md_nested_asks tool_wt_npmrc_nested_asks tool_wt_nested_plain_ok tool_wt_allow_only_mcp tool_wt_allow_only_claude_settings \
  tool_wt_github_workflow_asks tool_wt_gitmodules_asks tool_wt_gemini_md_nested_asks hook_wt_envrc_write autoallow_ask_rule_kept autoallow_deny_rule_kept \
  commit_bypass_config_flag commit_bypass_cd commit_bypass_dir_flag commit_bypass_config_flag_hooks commit_bypass_cd_hooks commit_bypass_dir_flag_hooks \
  commit_bypass_dir_flag_wtcwd commit_bypass_dir_flag_wtcwd_hooks \
  pnpm_dir_flag_add pnpm_dir_long_install pnpm_alias_i pnpm_npx_runner pnpm_plain_add_asks refs_cherry_pick refs_update_ref refs_write_ref_file refs_fetch_other_branch refs_branch_f_other_branch \
  refs_checkout_B refs_commit_plain_noask refs_ctl_add refs_ctl_stash refs_ctl_gate_commit gate_commit_ok gate_late_staged_logged gate_refuses_detached \
  gate_refuses_other_branch gate_refuses_unapproved gate_refuses_no_record gate_refuses_amend gate_refuses_separate_git_dir gate_plain_commit_in_worktree_hook \
  base_worktree_sandboxed_control base_worktree_excluded base_worktree_refuses_ticket_commit base_setup_sandboxed base_worktree_symlinked_dir \
  gitcfg_write_config gitcfg_write_config_worktree gitcfg_write_wt_config_worktree gitcfg_write_info_attributes gitcfg_write_config_hooks gitcfg_write_info_attributes_hooks \
  gitdir_hooks_new_file gitdir_hooks_new_file_hooks gitdir_hooks_mkdir gitdir_info_exclude gitdir_objects_write gitdir_wt_head_write setup_exclude_sandboxed; do
  grep -q "\"id\": \"$id\"" "$S/table.json" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL case $id missing from the probe"; }
done
# raw / settings files are named after the case id: on a case-insensitive filesystem two ids that differ only in case overwrite each other
python3 -c 'import json,sys; ids={r["id"] for r in json.load(open(sys.argv[1]))}; sys.exit(0 if len(ids) == len({i.lower() for i in ids}) else 1)' "$S/table.json" \
  && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL two case ids differ only in case"; }
echo "pass=$pass fail=$fail"; [ $fail = 0 ]
