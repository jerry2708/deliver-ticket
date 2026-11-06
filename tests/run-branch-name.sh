#!/bin/bash
# branch-name.py: final branch name from guard.json branch_naming. Usage: tests/run-branch-name.sh <new scratch dir>
set -u
S=${1:?scratch dir (must be empty or new)}
SK=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$S" && S=$(cd "$S" && pwd -P)
[ -z "$(ls -A "$S")" ] || { echo "scratch dir not empty" >&2; exit 2; }
pass=0; fail=0
eq() { [ "$1" = "$2" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $3: got [$1] want [$2]"; }; }
mkg() { printf '{"branch_naming":"%s"}\n' "$2" > "$S/$1.json"; }
B=$SK/scripts/branch-name.py
mkg real '{type}/{id-lowercase}-{slug}'; mkg old 'feature/{id}-{slug}'; mkg unk '{type}/{ticket}-{slug}'; mkg noid '{type}/{slug}'; mkg front '{type}/{slug}-{id}'
eq "$($B $S/real.json RETRO-7 fix 'Prompt tool args')" "fix/retro-7-prompt-tool-args" "real pattern"
eq "$($B $S/real.json RETRO-7 fix '')" "fix/retro-7" "empty slug leaves no trailing '-'"
eq "$($B $S/real.json RETRO-7 fix '   ---  ')" "fix/retro-7" "slug of punctuation only"
eq "$($B $S/real.json WL-05 feat 'Wishlist chat -> cart (move)!')" "feat/wl-05-wishlist-chat-cart-move" "punctuation folded"
eq "$($B $S/real.json WL-05 feat 'one two three four five six seven')" "feat/wl-05-one-two-three-four-five" "at most 5 words"
eq "$($B $S/real.json WL-05 feat 'abcdefghijklmnopqrstuvwxyz0123456789 abcdefghijklmnop')" "feat/wl-05-abcdefghijklmnopqrstuvwxyz0123456789" "40 characters, cut at a word boundary"
eq "$($B $S/real.json RETRO-8 chore 'Đổi tên nút Lưu')" "chore/retro-8-doi-ten-nut-luu" "accents folded"
eq "$($B $S/old.json WL-05 feat 'x y')" "feature/WL-05-x-y" "{id} keeps the case"
eq "$($B $S/front.json RETRO-7 fix '')" "fix/RETRO-7" "slug dropped in front leaves no '/-'"
$B $S/unk.json RETRO-7 fix x >/dev/null 2>&1; eq "$?" 2 "unknown placeholder -> 2"
$B $S/real.json RETRO-7 'Fix' x >/dev/null 2>&1; eq "$?" 2 "bad type -> 2"
$B $S/real.json '../x' fix x >/dev/null 2>&1; eq "$?" 2 "bad ID -> 2"
$B $S/missing.json RETRO-7 fix x >/dev/null 2>&1; eq "$?" 2 "missing guard.json -> 2"
# --repo: an existing local branch (3), a remote-tracking ref (4), a free name (0)
R=$S/repo; mkdir -p $R && git -C $R init -q -b main && git -C $R config user.email t@t && git -C $R config user.name t && git -C $R commit -q --allow-empty -m i
git -C $R branch fix/retro-7-a; git -C $R update-ref refs/remotes/training-v2/fix/retro-7-b HEAD
$B $S/real.json RETRO-7 fix a --repo $R >/dev/null 2>&1; eq "$?" 3 "local branch exists -> 3"
$B $S/real.json RETRO-7 fix b --repo $R >/dev/null 2>&1; eq "$?" 4 "remote-tracking ref exists -> 4"
$B $S/real.json RETRO-7 fix c --repo $R >/dev/null 2>&1; eq "$?" 0 "free name -> 0"
echo "pass=$pass fail=$fail"; [ $fail = 0 ]
