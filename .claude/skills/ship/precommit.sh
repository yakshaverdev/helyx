#!/usr/bin/env bash
# Runs `mix precommit` for the worktree in the current directory and writes
# the output to precommit.log. With a host set (an ssh target, in
# HELYX_PRECOMMIT_HOST or in ~/.config/helyx/precommit-host), it copies the worktree to that host and runs there, so parallel workers do
# not load this machine. The format step rewrites files, so the files that it
# changed on the host are copied back, the same as a local run. Nothing may
# edit the worktree during the run: a copied-back file replaces a local edit.
# A local run has no PID namespace. HELYX_SLOW=1 runs the slow tests too,
# as /ship and the merge gate of /orchestrate do (#295).
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

# Only 0 or 1 goes into the remote command line.
slow=0
[ "${HELYX_SLOW:-}" = 1 ] && slow=1

# The run has its own PID namespace, as the host user again, so a signal
# to -1 or to a wrong group from a test reaches only the run, never the
# other processes of the host (on 2026-09-30 one froze them all). The
# first process of the namespace is a root sh that only waits: it never
# changes its user, so the SIGKILL that unshare sets for it when the outer
# unshare dies stays set, and its end ends every process of the run. The
# run needs sudo without a password on the host; without it the run fails
# and does not run outside the namespace.
isolate="sudo -n unshare --pid --fork --mount-proc --kill-child=SIGKILL sh -c '\"\$@\"; exit \$?' pid1 setpriv --reuid=\$(id -u) --regid=\$(id -g) --init-groups env HOME=\"\$HOME\" LANG=C.UTF-8 HELYX_SLOW=$slow"
ssh -o BatchMode=yes "$host" "cd '$dir' && $sources > .before && $isolate ~/.local/bin/mise exec -- mix precommit" > precommit.log 2>&1
status=$?

# md5sum -c exits 1 on a changed file. Only status 0, or 1 with a
# FAILED line for each changed file and nothing else, is a clean check.
check=$(ssh -o BatchMode=yes "$host" "cd '$dir' && { md5sum -c --quiet .before 2>&1; echo \"md5sum status \$?\"; }") || {
  echo "failed: cannot read the format changes on $host"
  exit 1
}
changed=$(printf '%s\n' "$check" | sed -n 's/: FAILED$//p')
unexpected=$(printf '%s\n' "$check" | grep -v -E -e ': FAILED$' -e '^$' -e 'WARNING: [0-9]+ computed checksums? did NOT match$' -e '^md5sum status [01]$')
if [ -n "$unexpected" ] || ! printf '%s\n' "$check" | grep -qE '^md5sum status [01]$'; then
  printf 'failed: unexpected checksum output on %s:\n%s\n' "$host" "$check"
  exit 1
fi
if [ -n "$changed" ]; then
  printf '%s\n' "$changed" | rsync -a --ignore-times --files-from=- "$host:$dir/" ./ || exit 1
  printf 'format changed on %s and copied back:\n%s\n' "$host" "$changed"
fi

[ "$status" -eq 0 ] && echo passed || echo failed
exit "$status"
