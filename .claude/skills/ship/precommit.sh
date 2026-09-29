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
  mise exec -- mix precommit > precommit.log 2>&1
  status=$?
  [ "$status" -eq 0 ] && echo passed || echo failed
  exit "$status"
fi

dir="precommit/$(basename "$root")"
excludes=(--exclude=.git --exclude=_build/ --exclude=deps/ --exclude=.elixir_ls/
  --exclude=.scratch/ --exclude=precommit.log --exclude=tmp/ --exclude=cover/)
sources="find . \\( -name _build -o -name deps -o -name .scratch \\) -prune -o -type f \\( -name '*.ex' -o -name '*.exs' -o -name '*.heex' \\) -print0 | xargs -0 md5sum"

ssh -o BatchMode=yes "$host" "mkdir -p '$dir'" || exit 1
rsync -a --delete "${excludes[@]}" ./ "$host:$dir/" || exit 1

ssh -o BatchMode=yes "$host" "cd '$dir' && $sources > .before && ~/.local/bin/mise exec -- mix precommit" > precommit.log 2>&1
status=$?

# md5sum -c exits 1 on a changed file, so only the ssh status tells a
# transport failure; every output line must name a changed file.
check=$(ssh -o BatchMode=yes "$host" "cd '$dir' && { md5sum -c --quiet .before 2>&1; true; }") || {
  echo "failed: cannot read the format changes on $host"
  exit 1
}
changed=$(printf '%s\n' "$check" | sed -n 's/: FAILED$//p')
unexpected=$(printf '%s\n' "$check" | grep -v -E -e ': FAILED$' -e '^$' -e 'WARNING: [0-9]+ computed checksums? did NOT match$')
if [ -n "$unexpected" ]; then
  printf 'failed: unexpected checksum output on %s:\n%s\n' "$host" "$unexpected"
  exit 1
fi
if [ -n "$changed" ]; then
  printf '%s\n' "$changed" | rsync -a --files-from=- "$host:$dir/" ./ || exit 1
  printf 'format changed on %s and copied back:\n%s\n' "$host" "$changed"
fi

[ "$status" -eq 0 ] && echo passed || echo failed
exit "$status"
