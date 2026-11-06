#!/usr/bin/env bash
# The precommit steps of the worktree in the current directory, here or on
# the precommit host (precommit.sh runs this file in both places): `mix
# precommit` for the Mix projects, then for each Cargo workspace of
# clients/*/Cargo.toml `cargo fmt --check`, `cargo clippy` with warnings as
# errors, and `cargo test`. Cargo comes from the `rust` line of
# .tool-versions through `mise exec`, so it needs no PATH entry. Every step
# runs; the last line names each step that failed.
set -uo pipefail

mise=$(command -v mise || echo "$HOME/.local/bin/mise")
failed=()

"$mise" exec -- mix precommit || failed+=("mix precommit")

for manifest in clients/*/Cargo.toml; do
  [ -f "$manifest" ] || continue
  project=$(dirname "$manifest")
  for step in "fmt --check" "clippy --locked --all-targets -- -D warnings" "test --locked"; do
    echo "==> precommit $project: cargo $step"
    # shellcheck disable=SC2086 # the step is a list of words
    (cd "$project" && "$mise" exec -- cargo $step) || failed+=("$project: cargo $step")
  done
done

if [ ${#failed[@]} -gt 0 ]; then
  printf 'precommit failed: %s\n' "$(IFS=';'; echo "${failed[*]}")"
  exit 1
fi
