# Review: MCP client build (#492)

The build of `docs/features/mcp-client.md`, one `/ship` per slice of its "Slice order".

## Slice 1: tool name rule

Invariant: `Helyx.Tool.specs/2` accepts a tool name only when it is 1 to 52 bytes, each an ASCII letter, a digit, `_`, or `-`; any other name gives `{:bad_tool_spec, module}` before a session creates any file or process, and every bundled tool name passes.

Base `610a8d41`. Bounds sensor: `bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer`.

### Round 1 (full)

- Simplify: moved `@name_pattern` next to `name?/1`; removed a test that repeated the `"a\n"` row.
- Codex: approve, no finding (983 spec probes and 84 session entry probes).
- Failure path: no defect. Probes through `Session.start/2` and `resume/2`: 53 bytes, `"a\n"`, `"\na"`, a NUL, invalid UTF-8, a list, a bitstring, a space, `"é"` are all rejected with no file and no process; 52 bytes starts; a resume with a bad name leaves the file unchanged; a 100 MB name is rejected in 94 µs.
- Spec: no missing or wrong requirement. The bundled names test lives in `plugins/bundled` because the root project cannot load the bundled plugins. Guarantee table of the `@doc` of `specs/2`: every guarantee has a test but "a raise while a spec is built is not contained", which predates this change.
- Standards: one hard finding and three judgement calls.

| # | Finding | Resolution |
| - | ------- | ---------- |
| 1 | The `@doc` wrote the rule as `^...$`, which matches a trailing newline; the code uses `\A...\z` | the `@doc` and the test header state the rule in words |
| 2 | The code comment said every provider takes 64 bytes; decision 8 says 64 is the smallest known limit | comment fixed |
| 3 | `names_test.exs` mirrors no `lib/` module | renamed `bundled_names_test.exs`, `Helyx.Tool.BundledNamesTest`; later slices add their tools to its list |
| 4 | `boundary_test.exs` rows overlap the new file | kept: they test the session boundary, the new file tests `specs/2` |
| 5 | (failure path, out of axis) `docs/features/coding-agent.md` bounds row still said "the name non-empty" | row updated |

No round reproduced a defect, so the loop ended after round 1.
