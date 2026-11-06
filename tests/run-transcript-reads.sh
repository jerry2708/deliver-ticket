#!/bin/bash
# transcript-reads.py: flags tool calls that touch docs (with or without the slash) and searches for the ticket that are not
# restricted to code paths. The positive cases are the real commands of dry run 1 (RETRO-7, session e5ee55ac, transcript lines
# 90, 97, 100, 108). Usage: tests/run-transcript-reads.sh <new scratch dir>
set -u
S=${1:?scratch dir (must be empty or new)}
SK=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$S" && S=$(cd "$S" && pwd -P)
[ -z "$(ls -A "$S")" ] || { echo "scratch dir not empty" >&2; exit 2; }
pass=0; fail=0
eq() { [ "$1" = "$2" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $3: got [$1] want [$2]"; }; }
R=/Users/huynhminh/Desktop/Work/copilot-kit-training
python3 -I - "$S" "$R" <<'PY'
import json, sys
S, R = sys.argv[1], sys.argv[2]
def tu(name, **inp): return {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": name, "input": inp}]}}
real = {
 90: "cd %s; grep -rn --exclude='.env*' --exclude-dir=node_modules --exclude-dir=.mastra --exclude-dir=.next -iE 'purchasePlan|prepare-?purchase|productNameOrId' apps/agent/src --include=*.ts -l; echo ---; grep -n -iE 'purchase|productId|NameOrId' apps/agent/src/mastra/constants/prompts.ts; echo ---; sed -n 1,60p apps/agent/src/mastra/tools/prepare-purchase-plan.ts; ls docs 2>/dev/null; grep -rn \"RETRO-7\\|Retro #7\" --exclude-dir=node_modules --exclude-dir=.git -I . 2>/dev/null | head" % R,
 97: "cd %s; grep -rln --exclude='.env*' --exclude-dir=node_modules --exclude-dir=.mastra --exclude-dir=.next -iE 'purchasePlan|prepare-?purchase|productNameOrId' apps/agent/src; echo ---; grep -n -iE 'purchase|productId|NameOrId' apps/agent/src/mastra/constants/prompts.ts; echo ---; sed -n 1,60p apps/agent/src/mastra/tools/prepare-purchase-plan.ts; ls docs; git grep -n -e 'RETRO-7' -e 'Retro #7' -- ':!.env*' | head" % R,
 100: "cd %s; sed -n 165,215p apps/agent/src/mastra/constants/prompts.ts; echo ---; cat apps/agent/src/mastra/schemas/purchase-plan-contracts.ts | head -40; echo ---; grep -rn -iE 'retro' docs/training-v2 2>/dev/null | grep -iE '#7|RETRO-7|productNameOrId' | head; ls docs/training-v2 | head -30" % R,
 108: "cd %s; git grep -n -E 'moveWishlistItemToCart|NameOrId' -- apps packages ':!*.test.*' ':!.env*' | grep -v '^apps/agent/src/mastra/tools/prepare-purchase-plan.ts'| head -20; sed -n 20,45p docs/training-v2/deliver-ticket-sample-tiers.md | cut -c1-400" % R,
}
lines = [tu("Bash", command=real[n]) for n in (90, 97, 100, 108)]                                   # transcript lines 1-4 here
lines += [
 tu("Bash", command="grep -rn RETRO-7 apps/web/src"),                                               # 5  ticket search restricted to code: fine
 tu("Bash", command="git grep -n -e 'RETRO-7' -- apps packages ':!*.test.*'"),                      # 6  ditto (git grep, pathspecs in code)
 tu("Bash", command="git log --grep RETRO-7 --oneline"),                                            # 7  history is allowed
 tu("Bash", command="cat notes.txt | grep RETRO-7"),                                                # 8  filters stdin, not a file search
 tu("Grep", pattern="moveWishlistItemToCartTool", path="apps/web/src"),                             # 9  not a ticket term
 tu("Grep", pattern="RETRO-7", path="apps/web/src"),                                                # 10 code path: fine
 tu("Grep", pattern="RETRO-7"),                                                                     # 11 whole repo: flagged
 tu("Glob", pattern="**/*retro*.md"),                                                               # 12 title word, no code path: flagged
 tu("Bash", command="rg -n 'Retro #7'"),                                                            # 13 rg over the cwd: flagged
 tu("Bash", command="ls docs-old; ls node_modules/next/dist/docs/"),                                # 14 other dirs: not docs
 tu("Read", file_path=R + "/apps/web/src/tools/use-commerce-cart-tools.tsx"),                       # 15
]
with open(S + "/t.jsonl", "w") as f:
    for l in lines: f.write(json.dumps(l) + "\n")
    f.write("not json\n")
    f.write(json.dumps({"type": "user", "message": {"content": [{"type": "text", "text": "mentions docs and RETRO-7 but is not a tool call"}]}}) + "\n")
PY
T=$SK/scripts/transcript-reads.py
# --under only (the old behaviour, now also without the slash)
out=$($T "$S/t.jsonl"); eq "$?" 1 "under: rc 1"
for n in 1 2 3 4; do echo "$out" | grep -q "^line $n " && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL under: line $n (touches docs) not listed"; }; done
for n in 5 6 7 8 9 10 11 12 13 15; do echo "$out" | grep -q "^line $n " && { fail=$((fail+1)); echo "FAIL under: line $n must not be listed"; } || pass=$((pass+1)); done
echo "$out" | grep -q "^line 14 " && { fail=$((fail+1)); echo "FAIL docs-old / next docs must not match 'docs'"; } || pass=$((pass+1))
echo "$out" | grep -q '^line 2 .*touches docs: \.\.\..*; ls docs; git grep' && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL 'ls docs' without a slash not seen in line 2"; }
# --ticket / --title: searches for the ticket outside code paths
out=$($T "$S/t.jsonl" --ticket RETRO-7 --title 'Retro #7' --title retro); eq "$?" 1 "ticket: rc 1"
echo "$out" | grep -q "^line 1 .*search for the ticket" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL ticket: real line 90 (grep -rn RETRO-7 ... .) not flagged"; }
echo "$out" | grep -q "^line 2 .*search for the ticket.*git grep -n -e RETRO-7 -e Retro #7" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL ticket: real line 97 (git grep over the whole repo) not flagged"; }
echo "$out" | grep -q "^line 3 .*search for the ticket" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL ticket: real line 100 (grep -rn retro docs/training-v2) not flagged"; }
echo "$out" | grep -q "^line 4 .*search for the ticket" && { fail=$((fail+1)); echo "FAIL ticket: line 108 searches code symbols, not the ticket"; } || pass=$((pass+1))
for n in 5 6 7 8 9 10 15; do echo "$out" | grep -q "^line $n " && { fail=$((fail+1)); echo "FAIL ticket: line $n must not be listed"; } || pass=$((pass+1)); done
for n in 11 12 13; do echo "$out" | grep -q "^line $n " && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL ticket: line $n must be flagged"; }; done
echo "$out" | tail -1 | grep -qx '7 call(s) flagged' && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL count: $(echo "$out" | tail -1)"; }
# a code root can be changed
$T "$S/t.jsonl" --ticket RETRO-7 --code-root docs >/dev/null; [ $? = 1 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL --code-root run"; }
# another prefix, clean transcript, bad input
$T "$S/t.jsonl" --under node_modules/next/dist/docs/ >/dev/null; eq "$?" 1 "multi-segment prefix is matched as written (line 14)"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/r/a.ts"}}]}}' > "$S/clean.jsonl"
$T "$S/clean.jsonl" --ticket RETRO-7 >/dev/null; eq "$?" 0 "nothing found -> rc 0"
$T "$S/missing.jsonl" >/dev/null 2>&1; eq "$?" 2 "missing file -> rc 2"
# ---- dry run 2 (RETRO-7, session 8141a8cf): errored calls, exclusions, targets that cannot reach docs. Real inputs, verbatim.
python3 -I - "$S" "$R" <<'PY'
import json, sys
S, R = sys.argv[1], sys.argv[2]
def tu(i, name, **inp): return {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": i, "name": name, "input": inp}]}}
def res(i, err): return {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": i, "is_error": err, "content": "x"}]}}
WT = R + "/.claude/worktrees/RETRO-7"
grep92 = dict(pattern="productNameOrId|wishlist.*cart|moveWishlist|moveToCart", path=R, glob="!{node_modules,.next,.mastra,dist,.git}/**", output_mode="content")
l105 = "git grep -n -i -E 'productNameOrId|wishlist.*cart|moveWishlist|moveToCart|wishlistToCart' -- ':!*.lock' ':!pnpm-lock.yaml' ':!docs' | wc -l; git grep -n -i -E 'productNameOrId|wishlist.*cart|moveWishlist|moveToCart|wishlistToCart' -- ':!pnpm-lock.yaml' ':!docs'"
l495 = "cd %s/.playwright-mcp && grep -n -E 'Wishlist:|Cart:|Runtime info|Chat error|Connection error|textbox \"Type a message' page-2026-11-06T08-21-54-889Z.yml | cut -c1-200; cut -c1-250 console-2026-11-06T08-21-53-853Z.log | grep -E 'ERROR|401|WARNING' | head" % WT
l544 = "cd %s/.playwright-mcp && f=page-2026-11-06T08-23-51-960Z.yml; grep -n -E 'Wishlist:|Cart:|Remove .* from wishlist' $f | cut -c1-160; n=$(grep -n 'Copilot chat sidebar' $f | cut -d: -f1); sed -n \"${n},\\$p\" $f | cut -c1-400 | head -60" % WT
l553 = "grep -n -E 'Wishlist:|Cart:|from wishlist\"' page-2026-11-06T08-23-51-960Z.yml | grep -v 'Save ' | cut -c1-160; grep -n -A40 'Copilot chat sidebar' page-2026-11-06T08-23-51-960Z.yml | cut -c1-400"
l598 = "mv pre-run.yml /Users/huynhminh/.local/share/deliver-ticket/copilot-kit-training-cd02feca/evidence/RETRO-7/ac2-pre-run-snapshot.yml && git status --short; grep -n -i -E 'wishlist|401|403|500' /private/tmp/claude-501/-Users-huynhminh-Desktop-Work-copilot-kit-training/8141a8cf-afa5-493a-85e1-f5acc96ffa49/tasks/bew6b9lss.output | grep -v 'tool-call' | tail -15 | cut -c1-250; sed -n 1,60p apps/web/src/utils/wishlist-api.ts"
rows = [
 tu("toolu_01UB7o4sz3mdicuyi29nv4zE", "Grep", **grep92), res("toolu_01UB7o4sz3mdicuyi29nv4zE", True),        # 1,2 real line 92/96: the tool was not available (is_error)
 tu("toolu_ok", "Grep", **grep92),                                                                            # 3   same call that ran: reaches docs
 tu("t4", "Bash", command=l105),                                                                              # 4   real line 105: ':!docs' exclusion
 tu("t5", "Bash", command="cd %s && %s" % (R, l105)),                                                         # 5   real line 112
 tu("t6", "Bash", command=l495), tu("t7", "Bash", command=l544), tu("t8", "Bash", command=l553), tu("t9", "Bash", command=l598),  # 6-9 real: one file / $f / outside the repo
 tu("t10", "Bash", command="grep -rn wishlist ."),                                                            # 10  whole repo
 tu("t11", "Bash", command="git grep -n -i wishlist"),                                                        # 11  whole repo
 tu("t12", "Bash", command="grep -rn wishlist apps/web/src"),                                                 # 12  code path
 tu("t13", "Bash", command="rg -n wishlist -g '!docs'"),                                                      # 13  docs excluded
 tu("t14", "Bash", command="grep -rn wishlist --exclude-dir=docs ."),                                         # 14  docs excluded
 tu("t15", "Bash", command="grep -rn wishlist --exclude-dir=node_modules ."),                                 # 15  other exclusion: still reaches docs
 tu("t16", "Bash", command="grep -rn wishlist some/other/dir"),                                               # 16  unknown directory: can reach notes
 tu("t17", "Glob", pattern="**/*wishlist*.md"),                                                               # 17  glob over the repo
]
with open(S + "/t2.jsonl", "w") as f:
    for r in rows: f.write(json.dumps(r) + "\n")
PY
out=$($T "$S/t2.jsonl" --under docs --ticket RETRO-7 --title wishlist); eq "$?" 1 "dry run 2: rc 1"
echo "$out" | grep -q '^1 errored call(s) skipped' && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL errored call not skipped/counted: $out"; }
echo "$out" | grep -q '^line 1 ' && { fail=$((fail+1)); echo "FAIL errored Grep (real line 92/96) must be skipped"; } || pass=$((pass+1))
echo "$out" | grep -q 'would have been flagged if they had run (attempts, not counted): line 1 Grep' && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL errored attempt not named: $out"; }
for n in 3 10 11 15 16 17; do echo "$out" | grep -q "^line $n " && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL dry run 2: line $n must be flagged"; }; done
for n in 4 5 6 7 8 9 12 13 14; do echo "$out" | grep -q "^line $n " && { fail=$((fail+1)); echo "FAIL dry run 2: line $n must NOT be flagged"; echo "$out" | grep "^line $n " | cut -c1-200; } || pass=$((pass+1)); done
echo "$out" | grep -q '^1 search(es) for the ticket with an unresolvable' && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL \$f target not counted as unresolvable: $out"; }
echo "$out" | tail -1 | grep -qx '6 call(s) flagged' && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL count: $(echo "$out" | tail -1)"; }
# the exclusion pathspec alone must not make a call 'touch docs' (real lines 105 / 112 flagged by the old --under check)
$T "$S/t2.jsonl" >/dev/null; [ $? = 0 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL --under only: ':!docs' / --exclude-dir=docs / -g '!docs' must not count as touching docs"; }
echo "pass=$pass fail=$fail"; [ $fail = 0 ]
