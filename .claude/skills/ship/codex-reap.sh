#!/usr/bin/env bash
# Sends SIGTERM to the Codex review broker of each removed directory that it
# can prove gone (#538).
# The Codex plugin starts one detached `app-server-broker.mjs serve` per
# working directory, and nothing stops it when a worktree is removed. A broker
# whose `--cwd` directory no longer exists serves nobody. By the plugin source
# and a live run on 2026-10-12, its SIGTERM handler closes its Codex app server,
# and the whole process tree ends.
# A broker whose `--cwd` path still names a directory never gets the signal.
# A directory moved away from that path (`git worktree move`, a renamed
# parent) counts as gone, and its broker gets the signal. The script reads the
# process list of the current user once and prints how many brokers it sent
# SIGTERM to. It does not wait for them to exit.
#
# Usage: codex-reap.sh [dir]. With an absolute dir, only brokers whose `--cwd`
# lies under it are considered (the test uses this to touch only its own fakes).
# Run codex-reap-test.sh after a change to this script.
#
# A broker is skipped, and so never signalled, when its cwd is not printed
# exactly (see below), not absolute, has a `..` component, or cannot
# be proved gone (see the ENOENT check).
# Open, ticket #541: the pid can be reused between the read and the kill, and
# a directory can be made again at the cwd between the `stat` and the kill.
set -uo pipefail
# ps prints a byte that it cannot show in this locale as text that starts with
# `\`, `^` or `M-`. In the C locale that is every byte outside printable ASCII,
# so a cwd of printable ASCII without those marks is printed exactly.
export LC_ALL=C

scope=${1:-}
case $scope in '' | /*) ;; *) echo "codex-reap: the dir must be an absolute path" >&2; exit 2 ;; esac
scope=${scope%/}
procs=$(ps -U "$(id -u)" -ww -o pid=,ucomm=,args=) || { echo "codex-reap: ps failed" >&2; exit 1; }

signalled=0
while IFS=' ' read -r pid comm args; do
  # The plugin starts the broker as
  # `<node> <dir>/app-server-broker.mjs serve --endpoint unix:<S>/broker.sock --cwd <cwd> --pid-file <S>/broker.pid`.
  # ps joins the arguments with spaces, so the cwd is cut out between two
  # anchors that both name <S>: a cwd with spaces, or with the text of an
  # option, cannot shift the cut. The process must be node itself, not a
  # shell whose command text contains this line.
  [ "$comm" = node ] || continue
  pidfile=${args##* --pid-file }
  session=${pidfile%/broker.pid}
  [ "$session" != "$pidfile" ] || continue
  anchor="/app-server-broker.mjs serve --endpoint unix:$session/broker.sock --cwd "
  before=${args% --pid-file *}
  case $before in *"$anchor"*) ;; *) continue ;; esac
  cwd=${before#*"$anchor"}
  case $cwd/ in *\\* | *^* | *M-* | */../*) continue ;; esac
  # This also skips a relative cwd, as the scope is absolute or empty.
  case $cwd in "$scope"/*) ;; *) continue ;; esac
  # The cwd is gone only when the lookup fails with ENOENT. Any other error
  # (no search permission, a name too long, a symlink loop) can hide a
  # directory that exists. The C locale fixes the error text.
  err=$(stat -- "$cwd" 2>&1 >/dev/null) && continue
  case $err in *': No such file or directory') ;; *) continue ;; esac
  kill -TERM "$pid" 2>/dev/null && signalled=$((signalled + 1))
done <<<"$procs"

echo "codex-reap: sent SIGTERM to $signalled broker(s)"
