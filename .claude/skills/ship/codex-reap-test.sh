#!/usr/bin/env bash
# Test of codex-reap.sh (#538). It starts fake brokers (node processes with the
# broker's command line) in a temporary directory, runs the script scoped to
# that directory, and checks which fakes got SIGTERM. It touches no real
# broker. Run: .claude/skills/ship/codex-reap-test.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# An empty root would make the scoped runs below unscoped.
root=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
pids=()
cleanup() {
  for p in "${pids[@]}"; do kill -KILL "$p" 2>/dev/null; done
  chmod 755 "$root/locked" 2>/dev/null
  rm -rf "$root"
}
trap cleanup EXIT

mkdir "$root/bin"
echo 'process.on("SIGTERM", () => process.exit(0)); setInterval(() => {}, 1e6);' >"$root/bin/app-server-broker.mjs"

# Each wait polls up to load_tries times at 0.1 s: 5 s is the margin for a
# loaded machine.
load_tries=50

# Runs "$@" in the background and prints its pid once ps shows the broker
# command line (the fork precedes the exec). A process that does not show
# within the margin fails the test.
start() {
  local pid i
  "$@" </dev/null >/dev/null 2>&1 &
  pid=$!
  for i in $(seq "$load_tries"); do
    ps -p "$pid" -o args= | grep -q 'app-server-broker.mjs serve' && { echo "$pid"; return 0; }
    sleep 0.1
  done
  kill -KILL "$pid" 2>/dev/null
  return 1
}

# Sets `cmd` to the broker arguments for the cwd $1, as the plugin passes them.
broker_cmd() {
  local session
  session=$(mktemp -d "$root/cxc-XXXXXX")
  cmd=("$root/bin/app-server-broker.mjs" serve --endpoint "unix:$session/broker.sock"
    --cwd "$1" --pid-file "$session/broker.pid")
}

failures=0
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }
# The script sent SIGTERM before it returned, and node exits on it within
# milliseconds. A signalled fake gets the margin to exit. A live one is
# checked at once: the exact count proves that no other fake got a signal,
# as the script counts each kill that it sent.
check() { # $1 name, $2 pid, $3 expected state: alive or exited
  local state=alive i
  for i in $(seq "$load_tries"); do
    kill -0 "$2" 2>/dev/null || { state=exited; break; }
    [ "$3" = alive ] && break
    sleep 0.1
  done
  if [ "$state" = "$3" ]; then echo "ok: $1"; else fail "$1 is $state, expected $3"; fi
}

tab=$'\t'
mkdir -p "$root/live/sub" "$root/a b" "$root/p --pid-file q" "$root/t${tab}x" "$root/café" \
  "$root/locked/inner/sub" "$root/links"
ln -s "$root/locked/inner" "$root/lnk"
chmod 000 "$root/locked"
# A chain of 40 links to "$root/live" passes the kernel's limit of 32 links.
for i in $(seq 40); do ln -s "$root/links/l$((i + 1))" "$root/links/l$i"; done
ln -s "$root/live" "$root/links/l41"
# A live path longer than PATH_MAX (1024 bytes on macOS), made one name at a time.
name=$(printf 'n%.0s' $(seq 200))
long=$root
for i in $(seq 6); do long=$long/$name; done
(cd "$root" && for i in $(seq 6); do mkdir "$name" && cd "$name" || exit 1; done) || { echo "FAIL: long path"; exit 1; }
add() { # $1 variable name, $2 cwd
  local pid
  broker_cmd "$2"
  pid=$(start node "${cmd[@]}") || { fail "fake for $2 did not start"; exit 1; }
  pids+=("$pid")
  printf -v "$1" %s "$pid"
}
add gone "$root/gone"
add live "$root/live"
add space_live "$root/a b"
add space_gone "$root/x y"
add option_live "$root/p --pid-file q"
# "$root/a" is gone, a prefix of the live "$root/a b".
add prefix_gone "$root/a"
# ps prints these names as codes, so the script cannot read them and skips
# them, live or gone.
add tab_live "$root/t${tab}x"
add tab_gone "$root/u${tab}x"
add accent_live "$root/café"
add accent_gone "$root/gonecafé"
# The lookup of "inner" fails for lack of permission, not because it is gone.
add locked_live "$root/locked/inner"
add link_locked_live "$root/lnk"
add below_link_locked_live "$root/lnk/sub"
add loop_live "$root/links/l1/sub"
add long_live "$long"
# The path does not resolve, but "$root/live" exists.
add dots_live "$root/gone/../live"
# A pid file that does not end in /broker.pid is not the broker shape.
session=$(mktemp -d "$root/cxc-XXXXXX")
shape=$(start node "$root/bin/app-server-broker.mjs" serve --endpoint "unix:$session/broker.sock" \
  --cwd "$root/gone-shape" --pid-file "$session") || { fail "shape fake did not start"; exit 1; }
pids+=("$shape")
# A shell whose command text holds a broker line is not a broker.
broker_cmd "$root/gone-sh"
shell=$(start sh -c "while :; do sleep 1; done; : ${cmd[*]}") || { fail "shell did not start"; exit 1; }
pids+=("$shell")

"$here/codex-reap.sh" relative >/dev/null 2>&1
[ $? -eq 2 ] || fail "a relative dir is not rejected"

out=$("$here/codex-reap.sh" "$root/elsewhere")
[ "$out" = "codex-reap: sent SIGTERM to 0 broker(s)" ] || fail "scope: $out"

out=$("$here/codex-reap.sh" "$root")
echo "$out"
[ "$out" = "codex-reap: sent SIGTERM to 3 broker(s)" ] || fail "count: $out"
check "gone dir gets SIGTERM" "$gone" exited
check "live dir stays" "$live" alive
check "live dir with a space stays" "$space_live" alive
check "gone dir with a space gets SIGTERM" "$space_gone" exited
check "live dir named like an option stays" "$option_live" alive
check "gone prefix of a live dir gets SIGTERM" "$prefix_gone" exited
check "live dir with a tab stays" "$tab_live" alive
check "gone dir with a tab is skipped" "$tab_gone" alive
check "live dir with an accent stays" "$accent_live" alive
check "gone dir with an accent is skipped" "$accent_gone" alive
check "live dir under a locked parent stays" "$locked_live" alive
check "link to a live dir under a locked parent stays" "$link_locked_live" alive
check "live dir below that link stays" "$below_link_locked_live" alive
check "live dir behind too many links stays" "$loop_live" alive
check "live dir with a path over PATH_MAX stays" "$long_live" alive
check "live dir behind a .. component stays" "$dots_live" alive
check "another pid file shape stays" "$shape" alive
check "shell with a broker line in its text stays" "$shell" alive

[ "$failures" -eq 0 ] && echo passed || { echo "$failures failed"; exit 1; }
