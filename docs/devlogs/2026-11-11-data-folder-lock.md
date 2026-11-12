# Data folder lock

## What changed

The lock of each session became one lock for each Core on its data folder
(`docs/features/session-lock.md`).

- `Helyx.Core.FolderLock` is the first child of Core when `:sessions_dir` is
  set. It takes `flock` on `<sessions_dir>/core.lock` with
  `Helyx.Session.Lock`, holds it for the life of Core, and releases it at the
  stop. Its end stops Core (`auto_shutdown: :any_significant`).
- `Helyx.Session.Lock` is the generic `flock` helper. `take/1` gives
  `{:error, :locked}`. `hold/2`, the copy commands (`c`, `a`, `k`), the rename
  command (`m`), and their functions go. `w` and `r` stay for `helyx serve`.
- A session no longer takes a lock. `save` is `{:saving, file}` or
  `{:stopped, from}`; `State.lock/1`, the port clauses of the session, the
  release in the stop, and `Killer.move/2` go. `Stop.shutdown_ms/0` is
  30,000 ms.
- `Helyx.Session.start/2` and `resume/2` accept only the `:sessions_dir` of
  the Core, or none (`Input.sessions_dir/2`).
- `Helyx.Session.File.Edit` excludes a session of the same id through the
  Registry: it registers `{:edit, id}`, then looks up the id. The open looks
  up `{:edit, id}` and refuses with `:editing`. The edit writes the copy, the
  rename, and the removes in the BEAM in its Task.
- `Helyx.Hub.Delivery` retries `:editing`. `CodingAgent.error_text/1` gives
  the one line for `{:data_folder_locked, dir}`.

## Departures from the design

- `Helyx.Core.FolderLock` expands `.` and `..` in the folder before it takes
  the lock. `Helyx.Session.File.mkdir/1` already does this, so a folder path
  that the tests of #683 use (`sessions/new/..`) would otherwise fail the
  take with `:enoent`. `Helyx.Core.config/2` keeps the caller's spelling, and
  the guard of `:sessions_dir` compares that spelling.
- `Helyx.Test.SavedSession.start/2` uses the data folder of the Core. The
  TUI test modules start their Core with a folder (a per-test temporary
  folder) instead of the folder that the helper made.
- `Helyx.Test.UnsavedSession.stop_saving/1` moves the project folder away,
  appends a model change, waits for `{:stopped, _}`, then sets the model back
  and moves the folder back. The model change is the append that fails; the
  restore keeps the model that the tests expect after the call.
- `SwitchTest` "a failed resume shows the error and stays on the current
  session" now corrupts the saved model to a provider that the Core does not
  have, because two Cores cannot share one folder. Its line is the fixed
  unknown-provider text.
- Tests that started a second Core on the sessions folder of the first use a
  subfolder of it: `BoundaryTest`, `ModelContextTest`, `OutputLimitTest`,
  `TurnRecordTest`, `AgentTest`, the two `HelyxToolsTest`, `ConformanceTest`,
  and the two `SwitchTest` cases. Each keeps the property that it tests.
- `Helyx.Test.SessionCase.start_core/1` starts the Core on `tmp_dir` when the
  context has it; `start_core/2` passes options.

## Tests deleted, and why

- `lock_test` (now `open_test`): the lock tests of a session, the take of
  each open, the release at each stop, the lost-lock notice, the take after a
  caller dies, the moved deadline, the stop past the release bound, the perl
  that ends during the open, the copy commands, and the file command after
  the lock ends. The property that each kept is in
  `docs/features/session-lock.md`, "Replaced mechanism".
- `sessions_edit_test`: "a lock that another process holds is refused", and
  the describes "a session that lost its lock" and "a removal whose lock
  holder ends". The Core lock keeps the first; the Registry exclusion keeps
  the others (new test "an edit in progress refuses a resume and a second
  edit, and then completes").
- `print_test`: "a session open in another process is one line and 1".
- `test/support/shared/lost_lock.ex`: `LostLock.kill/1` kills a perl that no
  longer exists. `UnsavedSession.stop_saving/1` replaces it.

## New tests

- `test/helyx/core/folder_lock_test.exs`: a second Core fails, a stop frees
  the folder, a lost lock stops Core, a take makes no missing folder, and a
  `core.lock` that is not a regular file fails the start with no perl left.
- `lock_perl_test.exs`: "a session of the Core starts no perl", with an empty
  PATH after the Core start.
- `sessions_edit_test.exs`: the exclusion in both directions, the mode of the
  copy, and the removal of a symlink at the copy path.
- `serve_test.exs`: the one line of the data folder lock.

## Next

- The slow test of the edit deadline (`sessions_edit_test` "the kill of the
  killer is :timeout") still runs in the merge gate.
- Old `<id>.lock` files stay on disk. Nothing reads them; a cleanup is out of
  scope.
