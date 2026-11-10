#!/usr/bin/env bash
# Runs the precommit steps of precommit-run.sh (`mix precommit`, and the
# Cargo steps of clients/*/Cargo.toml) for the worktree in the current
# directory and writes the output to precommit.log. With a host set (an ssh target, in
# HELYX_PRECOMMIT_HOST or in ~/.config/helyx/precommit-host), it copies the worktree to that host and runs there, so parallel workers do
# not load this machine. The format step rewrites files, so the files that it
# changed on the host are copied back, the same as a local run. Nothing may
# edit the worktree during the run: a copied-back file replaces a local edit.
# A local run has no PID namespace. HELYX_SLOW=1 runs the slow tests too,
# as the merge gate of /orchestrate does; /ship runs without them (#295).
# On the host, the runs wait in a queue (#330). Each run holds a flock on
# ~/.helyx-precommit.lock, so only one run at a time loads the host. A run
# that must wait writes a line to precommit.log when the wait starts. Each
# run writes the wait in seconds. flock buffers that line, so it comes at
# the end of the run, and a killed run has none. The wait is unbounded,
# and accepted. The end of this script or of its ssh ends its run on the
# host, at any stage. The tests of the run that holds the lock have
# timeouts, but a hung compile or Dialyzer step of that run blocks the
# queue until its caller ends. A local run takes the same lock when flock
# exists, so on the host it waits in the same queue.
set -uo pipefail

root=$(git rev-parse --show-toplevel) || exit 1
cd "$root" || exit 1

# Prints the result and exits with status `$1`. A failed run's log is kept
# in the git common dir, which outlives the worktree and the next run (#455).
finish() {
  if [ "$1" -eq 0 ]; then
    echo passed
  else
    kept="$(git rev-parse --path-format=absolute --git-common-dir)/precommit-fails"
    kept="$kept/$(date -u +%Y%m%dT%H%M%SZ)-$(git rev-parse --abbrev-ref HEAD | tr / -).log"
    mkdir -p "$(dirname "$kept")" && cp precommit.log "$kept"
    echo "failed (log kept in $kept)"
  fi
  exit "$1"
}

# A change of Markdown files only (and .gitattributes) cannot fail format,
# compile, Credo, Dialyzer or a test, so it skips the run. The one Markdown
# file that a test reads is the wire doc (web_socket_test.exs checks its
# schema); a change to it runs precommit. A failed git call runs precommit.
if base=$(git merge-base origin/master HEAD 2>/dev/null) &&
  changed=$({ git diff --name-only "$base" && git ls-files --others --exclude-standard; } 2>/dev/null) &&
  [ -n "$changed" ] &&
  ! printf '%s\n' "$changed" | grep -v -E '\.md$|^\.gitattributes$' | grep -q . &&
  ! printf '%s\n' "$changed" | grep -qx 'docs/features/wire-protocol.md'; then
  printf 'precommit: skipped, the change is Markdown only:\n%s\n' "$changed" > precommit.log
  echo passed
  exit 0
fi

host=${HELYX_PRECOMMIT_HOST:-$(cat ~/.config/helyx/precommit-host 2>/dev/null)}

if [ -z "$host" ]; then
  # A local run waits in the queue of the host's runs (the same lock).
  # Without flock (macOS) it has none. flock exits with the run's status.
  # The wait and the run are one process group (setsid). A signal to this
  # script sends SIGKILL to the group, as the end of the namespace does on
  # the host: a run killed while it waits must not take the lock later, and
  # one killed while it runs must not keep it. The trap is set before the
  # fork and reads `$!`, empty until then; it also kills `$!` itself, a
  # child that has not yet called setsid. A SIGKILL of this script leaves
  # the group running (accepted). A background job starts with INT and QUIT
  # ignored, so env sets them to the default for the run, as on the host.
  if command -v flock > /dev/null; then
    {
      flock -n ~/.helyx-precommit.lock true || echo 'precommit: waiting for the host lock'
      trap '[ -z "${!:-}" ] || kill -KILL -- "-$!" "$!" 2> /dev/null; exit 143' TERM INT HUP
      setsid flock --verbose ~/.helyx-precommit.lock env --default-signal=INT,QUIT bash .claude/skills/ship/precommit-run.sh &
      wait "$!"
    } > precommit.log 2>&1
  else
    bash .claude/skills/ship/precommit-run.sh > precommit.log 2>&1
  fi
  finish $?
fi

dir="precommit/$(basename "$root")"
excludes=(--exclude=.git --exclude=_build/ --exclude=deps/ --exclude=.elixir_ls/
  --exclude=.scratch/ --exclude=precommit.log --exclude=tmp/ --exclude=cover/
  --exclude=target/ --exclude=_build.seed/ --exclude=deps.seed/ --exclude=/.built)
sources="find . \\( -name _build -o -name deps -o -name .scratch -o -name '*.seed' \\) -prune -o -type f \\( -name '*.ex' -o -name '*.exs' -o -name '*.heex' \\) -print0 | xargs -0 md5sum"

# Each ssh, and the ssh of each rsync, ends 120 s after the host stops
# answering (4 keepalives, 30 s apart), so a dead connection fails the run
# and does not hang it. A live run that prints nothing, such as a wait for
# the lock, still answers them.
ssh_opts=(-o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=4)
ssh "${ssh_opts[@]}" "$host" "mkdir -p '$dir'" || exit 1
rsync -a --delete -e "ssh ${ssh_opts[*]}" "${excludes[@]}" ./ "$host:$dir/" || exit 1

# Only 0 or 1 goes into the remote command line.
slow=0
[ "${HELYX_SLOW:-}" = 1 ] && slow=1

# The run has its own PID namespace, as the host user again, so a signal
# to -1 or to a wrong group from a test reaches only the run, never the
# other processes of the host (on 2026-09-30 one froze them all). The
# first process of the namespace is a root sh that never changes its user,
# so the SIGKILL that unshare sets for it when the outer unshare dies stays
# set, and its end ends every process of the run. The run needs sudo
# without a password on the host; without it the run fails and does not
# run outside the namespace.
# The first process starts the run in the background, with stdin on
# /dev/null, and a watcher on the stdin of the ssh channel, which nothing
# writes. A background job of sh gets stdin on /dev/null, so the channel
# is kept on fd 3 for the watcher. The end of that input makes the watcher
# send HUP to the first process only ($$ is 1 in the namespace), and its
# trap exits it, which ends the namespace. sh cannot trap a signal that it
# starts with ignored, and it starts a background job with INT and QUIT
# ignored, so env sets HUP to the default for the first process, and INT
# and QUIT for the run, as for a local run. When the network is lost with
# no close of the connection, the local ssh ends after 120 s (ssh_opts),
# and the run on the host ends when TCP gives up there: about 15 min after
# the first unanswered write, or about 2 h 11 min for a run that waits for
# the lock and writes nothing (keepalive of the host on 2026-11-08: 7200
# s, then 9 probes of 75 s). Accepted.
pid1='trap "exit 129" HUP; exec 3<&0; "$@" </dev/null 3<&- & run=$!; { cat >/dev/null; kill -s HUP $$; } <&3 & exec 3<&-; wait "$run"'
isolate="sudo -n unshare --pid --fork --mount-proc --kill-child=SIGKILL env --default-signal=HUP sh -c '$pid1' pid1 setpriv --reuid=\$(id -u) --regid=\$(id -g) --init-groups env --default-signal=INT,QUIT HOME=\"\$HOME\" LANG=C.UTF-8 HELYX_SLOW=$slow"
# The lock is taken inside the namespace, and the run inherits it. So flock,
# mise and the Mix VM hold it. The end of the namespace ends them all. A
# `kill -1` from a test cannot free the lock while the run goes on. A signal
# to the remote shell cannot free it either. The check before the namespace
# only writes the line for a wait, and under a race that line can be wrong.
# --verbose writes the real wait in seconds.
lock="~/.helyx-precommit.lock"
announce="{ flock -n $lock true || echo 'precommit: waiting for the host lock'; }"
# The ssh reads a FIFO whose only writer is fd 3 of this script. Nothing
# writes it, and the end of this script, by any signal, closes it. The
# read-write open of fd 3 does not wait for a reader. It comes first, so
# the read-only open of fd 4 does not wait for a writer. A kill before the
# rm leaves the empty FIFO in a temp folder; no run has started (accepted).
fifo_dir=$(mktemp -d) || exit 1
mkfifo "$fifo_dir/stdin" || { rm -r "$fifo_dir"; exit 1; }
exec 3<>"$fifo_dir/stdin" 4<"$fifo_dir/stdin"
rm -r "$fifo_dir"
# The run is wrapped, under the lock, so no other run writes any build.
# A folder with no root _build, a new one, starts warm: it gets a copy of
# _build and deps of each project from the folder of the latest run that
# passed, the one with the newest .built and a _build. A run removes
# .built at its start and writes it only when it passes, so a killed or
# failed run is never a source. The project PLTs of Dialyzer are in
# _build; the core PLTs are in the Mix home, which all folders share. A
# copy, never a move or a link: two folders never share a build. A seed is
# all or nothing, from one source: it first removes the _build and deps
# of each project, copies to .seed names, and renames them into place, the
# root _build last. A seed that fails removes them all and the run goes on
# cold; one that dies has no root _build, so the next run seeds again. A
# removal that fails stops the run: Mix or Credo would read what is left.
# Only the wrapper touches .seed and .built: the rsync excludes them.
# Mix recompiles a project in full when its manifests name another folder;
# Dialyxir keeps a copied PLT while mix.lock and the apps are the same.
wrap='projects() { for p in . plugins/* apps/*; do [ -d "$p" ] && echo "$p"; done; }
clear() { for p in $(projects); do for x in $1; do rm -rf "$p/$x" || { echo "precommit: cannot remove $p/$x"; exit 1; }; done; done; }
rm -f .built || { echo "precommit: cannot remove .built"; exit 1; }
clear "_build.seed deps.seed"
if [ ! -d _build ]; then
  s=$(date +%s)
  src=$(find .. -mindepth 2 -maxdepth 2 -name .built -printf "%T@ %h\n" | sort -rn | while read -r t d; do [ -d "$d/_build" ] && [ ! -L "$d/_build" ] && { echo "$d"; break; }; done)
  if [ -z "$src" ]; then echo "precommit: no folder to seed from; the run is cold"
  else
    clear "_build deps"
    if (for p in $(projects); do for x in _build deps; do [ ! -d "$src/$p/$x" ] || [ -L "$src/$p/$x" ] || cp -a "$src/$p/$x" "$p/$x.seed" || exit 1; done; done) &&
      (for p in $(projects | sort -r); do for x in deps _build; do [ ! -d "$p/$x.seed" ] || mv "$p/$x.seed" "$p/$x" || exit 1; done; done); then
      echo "precommit: seeded _build and deps from ${src#../} in $(($(date +%s) - s)) s"
    else
      clear "_build deps _build.seed deps.seed"
      echo "precommit: the seed from ${src#../} failed; the run is cold"
    fi
  fi
fi
"$@"; status=$?
[ "$status" != 0 ] || touch .built
exit "$status"'
ssh "${ssh_opts[@]}" "$host" "cd '$dir' && $sources > .before && $announce && $isolate flock --verbose $lock sh -c '$wrap' run bash .claude/skills/ship/precommit-run.sh" <&4 3>&- 4<&- > precommit.log 2>&1
status=$?
exec 3>&- 4<&-

# md5sum -c exits 1 on a changed file. Only status 0, or 1 with a
# FAILED line for each changed file and nothing else, is a clean check.
check=$(ssh "${ssh_opts[@]}" "$host" "cd '$dir' && { md5sum -c --quiet .before 2>&1; echo \"md5sum status \$?\"; }") || {
  echo "failed: cannot read the format changes on $host"
  finish 1
}
changed=$(printf '%s\n' "$check" | sed -n 's/: FAILED$//p')
unexpected=$(printf '%s\n' "$check" | grep -v -E -e ': FAILED$' -e '^$' -e 'WARNING: [0-9]+ computed checksums? did NOT match$' -e '^md5sum status [01]$')
if [ -n "$unexpected" ] || ! printf '%s\n' "$check" | grep -qE '^md5sum status [01]$'; then
  printf 'failed: unexpected checksum output on %s:\n%s\n' "$host" "$check"
  finish 1
fi
if [ -n "$changed" ]; then
  printf '%s\n' "$changed" | rsync -a --ignore-times -e "ssh ${ssh_opts[*]}" --files-from=- "$host:$dir/" ./ || finish 1
  printf 'format changed on %s and copied back:\n%s\n' "$host" "$changed"
fi

finish "$status"
