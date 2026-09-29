#!/usr/bin/env bash
# Runs `mix precommit` for the worktree in the current directory and writes
# the output to precommit.log. With a host set (an ssh target, in
# HELYX_PRECOMMIT_HOST or in ~/.config/helyx/precommit-host), it copies the worktree to that host and runs there, so parallel workers do
# not load this machine. The format step rewrites files, so the files that it
# changed on the host are copied back, the same as a local run.
set -uo pipefail

root=$(git rev-parse --show-toplevel) || exit 1
cd "$root" || exit 1

host=${HELYX_PRECOMMIT_HOST:-$(cat ~/.config/helyx/precommit-host 2>/dev/null)}

if [ -z "$host" ]; then
  mise exec -- mix precommit > precommit.log 2>&1 && echo passed || { echo failed; false; }
  exit
fi

dir="precommit/$(basename "$root")"
excludes=(--exclude=.git --exclude=_build/ --exclude=deps/ --exclude=.elixir_ls/
  --exclude=.scratch/ --exclude=precommit.log --exclude=tmp/ --exclude=cover/)
sources="find . \\( -name _build -o -name deps -o -name .scratch \\) -prune -o -type f \\( -name '*.ex' -o -name '*.exs' -o -name '*.heex' \\) -print0 | xargs -0 md5sum"

ssh -o BatchMode=yes "$host" "mkdir -p '$dir'" || exit 1
rsync -a --delete "${excludes[@]}" ./ "$host:$dir/" || exit 1

ssh -o BatchMode=yes "$host" "cd '$dir' && $sources > .before && ~/.local/bin/mise exec -- mix precommit" > precommit.log 2>&1
status=$?

changed=$(ssh -o BatchMode=yes "$host" "cd '$dir' && md5sum -c --quiet .before 2>/dev/null | sed 's/: FAILED\$//'")
if [ -n "$changed" ]; then
  printf '%s\n' "$changed" | rsync -a --files-from=- "$host:$dir/" ./ || exit 1
  printf 'format changed on %s and copied back:\n%s\n' "$host" "$changed"
fi

[ "$status" -eq 0 ] && echo passed || { echo failed; false; }
