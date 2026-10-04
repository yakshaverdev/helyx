# Review: context files from the root to the working directory (#481)

Date: 2026-10-04. Base: `origin/master` 58ae388.

Invariant: the only entry point is `Helyx.ModelContext.Default.build/2`. It adds the global file `~/.helyx/AGENTS.md`, then one file for each folder from `/` down to the working directory (the first regular file of `AGENTS.override.md`, `AGENTS.md`, `CLAUDE.md`). Each file loads at most once by device and inode, is read by `Helyx.Text.read_file/1`, and is capped by `Helyx.Text.truncate/2`. The text after the base prompt is at most 102,400 bytes, filled nearest file first, and stops at the first file that does not fit. Accepted holes are in `docs/features/context-files.md`, "Bounds".

## Bounds sensor

```text
bounds sensor: 3 candidate functions, 0 flagged, 0 without an answer
```

## Simplify

| Angle | Finding | Resolution |
| --- | --- | --- |
| Simplification | The test "home in the chain loads its file once" cannot fail: home is no longer a second walk | Deleted; the global-folder and symlink tests check the double paths. |
| Simplification | Two tests of a folder without a file checked the same thing | Merged into one. |
| Efficiency | Files past the cap were still read, up to 10 MiB each | Fixed: files are read nearest first through a `Stream`, and the read stops at the first file that does not fit. |
| Reuse, altitude | `@max_total_bytes` was a literal that its comment tied to the per-file cap | Fixed: `2 * Helyx.Text.max_bytes()`, in the code and the test. |
| Efficiency | Up to three stats per folder, and one extra stat per loaded file | Kept: microseconds against a model call. |

## Round 1 (full)

| Axis | Finding | Resolution |
| --- | --- | --- |
| Standards | No feature doc and no "Replaced mechanism" section | Fixed: `docs/features/context-files.md`. |
| Standards, spec | No test one byte under the total cap | Fixed: added. |
| Standards | The moduledoc has no link to a feature doc | Fixed. |
| Standards | `@names` does not say what it names | Fixed: `@file_names`. |
| Standards | The test copies the cap from the module; `count/2` and `first_regular/1` names | Kept: judgement calls. The copy is derived from `Helyx.Text.max_bytes/0`, and the one-over test fails if the factor changes. |
| Standards | The tests read the real files above the test folder | Kept: the walk starts at `/` by spec. The tests assert only on their own files, and the cap keeps the nearest files first. |
| Spec, failure path | The comment "room for two files at the per-file cap" is false: a section at the cap is 51,200 bytes of line content plus newlines, the notice and the heading (reproduced: two such sections need 102,632 bytes) | Fixed: the comment says only that one file at the cap always fits. |
| Spec | The old "no file anywhere" test has no exact replacement | Recorded in the feature doc: the walk from `/` makes that state unreachable in a test. |
| Spec | With cwd in `~/.helyx`, the global file keeps its first place and the cap drops it first | Accepted, recorded in the feature doc. |
| Failure path | A git worktree nested in its main checkout loads both `AGENTS.md` files (different inodes) | Not a defect: the ticket asks for every folder from the root. Recorded as accepted in the feature doc; a stop at the repository root needs a ticket. |
| Failure path | At the cap, one under, one over, multibyte: correct. `cost < left` or no separator cost fails the boundary tests | None. |
| Codex adversarial | The one-over fixture was over the per-file cap, so truncation hid the boundary | Already fixed in the working tree before the finding came in (Codex read an earlier state); the exact-cap test now also asserts 102,400 bytes, as Codex advised. |

Not reached: a world-writable parent folder such as `/tmp` (the probe did not write outside the worktree; recorded as accepted), filesystems without unique inodes.

No code defect was reproduced, only wording, doc, and test findings, so the loop ends after round 1.
