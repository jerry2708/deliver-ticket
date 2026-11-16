# Adapter: GitLab via `glab` (glab 1.124.0)

Checked against a local mock server: `mr create ... --description-file`, `mr update --description-file`, `mr note create`. Checked only in `--help`: `--draft` / `--ready` on `mr update`, `-l` and `--draft` on `mr create`, `mr view --comments`, `glab auth status` - if one fails when run, use `manual.md` for that step and tell me.

The core calls four capabilities: **check**, **create**, **update**, **comments**. Anything below that fails or is missing -> use `adapters/manual.md` for that step. Set `GLAB_SEND_TELEMETRY=0` for every glab call (or `glab config set telemetry false`). Never `-d -` (it waits on a prompt; blocked by the guard), never `-f field=@file` (sends the literal text), never `glab mr merge`.

- **check:** `glab auth status` (host and login); `git remote get-url <push remote>` is the allowed remote from config. Not authenticated -> I log in; you never type a token.
- **create** (only at stop points `draft-mr` / `ready-mr`): first push with `<skill dir>/scripts/git-push.sh <allowed-remote> <branch>` (I approve the prompt). Then `glab mr create -s <branch> -b <target> -t "<title>" --description-file <state>/evidence/<ID>/mr.md --push=false --yes` plus `--draft` for `draft-mr`, and `-l <labels>` from config. The description arrives exactly as the file.
- **update:** `glab mr update <n> --description-file <file>` (title: `-t`; draft state: `--draft` / `--ready`).
- **comments:** read: `glab mr view <n> --comments`; reply (only text I approved, and only when I said to post): `glab mr note create <n> < reply.md` (trailing newline stripped - harmless). Only if the CLI has no flag: `glab api ... -F field=@file`.
- Outputs (MR URL, numbers) are recorded in the ticket file.
