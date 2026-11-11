# Search tools: `grep` and `find`

## Goal

The agent searches a repository many times in one task. Before this change each
search was a `bash` call: a `bash` call can do anything, so an approval rule
cannot allow it without a prompt, and its result is one tail of the command's
output (`Helyx.Text.truncate/2`), with no count of the matches that it leaves
out. With `grep` and `find`, a product allows the two read-only tools once, and
the agent searches with no prompt, with each line cut, and with a count of what
the result does not show.

Decisions:

1. **They are Tool plugins, and the walk is Elixir** (ADR 0005). `Helyx.Tool.Grep`
   and `Helyx.Tool.Find` are bundled plugins, and the code they share is the
   helper `Helyx.Search` (`@moduledoc false`, no interface, no registration
   entry). The walk uses `File.ls/1` and `File.lstat/1` and starts no program, so
   the tools behave the same on every machine and hold no process group.
2. **A search follows the path rules of `read`.** `path` is expanded against the
   session folder with `Path.expand/2`; an absolute path, and a path with `..`
   that leaves the folder, are allowed, as `read` allows them; the tool refuses
   only what `read` refuses. A product that must keep a search inside the
   folder uses its approval rule, not the tool. Reason: a tool that refused a
   path that `read` accepts would give the model two rules for one argument, and
   `read` has no rule against a path outside the folder.
3. **The walk skips a fixed list of folders, and no ignore file.** `.git`,
   `_build`, `deps`, `node_modules`, `target`, and `.elixir_ls` are skipped by
   name at any depth, and every other name is walked, a dot file too. A walk
   that read the ignore rules would run `git ls-files`, an external program
   whose output is a listing of the whole work tree, which needs its own bound
   and its own release; this tool owns neither. Reason: the fixed list covers
   the folders that hold most bytes in the repositories of this product, the
   entry bound holds the rest, and the rule is testable with no repository.
4. **The walk visits at most `max_entries/1` entries under `deadline_ms/1`, and
   it returns what it found.** Past either bound the result holds the matches or
   paths found so far and a last line that says the search stopped early, and
   why. The last line is `[search stopped early: the 50000 entry limit]` or
   `[search stopped early: the 10000 ms deadline]`, with the values of
   `max_entries/1` and `deadline_ms/1`. Reason: a folder can hold any number of
   entries, and a search must return. A `grep` reports each file it finishes,
   so a Task killed at the deadline keeps those results; a `find` reports every
   1,024 entries.
5. **One regex match has no time bound of its own.** `Regex` gives a match a
   limit in steps, not in time, so the walk checks `deadline_ms/1` before each
   entry and each line, and the tool runs the walk in a Task that
   `Task.shutdown/2` kills at the same deadline. Reason: a pattern that
   backtracks on one long line would otherwise hold the call past every bound.
   `docs/research/coding-tools.md` records that the other terminal agents bound
   tool output; this is the same reason.
6. **A match shows the line, cut.** A file is read whole by
   `Helyx.Text.read_file/2` with `max_file_bytes/0`, so a file that is not valid
   UTF-8 or is over the bound is skipped and counted, not repaired. Each shown
   line is cut to `max_line_bytes/0` at a character boundary and ends in `…`, so
   one long line cannot fill the result. The whole result stays under
   `Helyx.Message.max_result_bytes/0` through `budget/0`.
7. **The glob is a small function of the helper.** `Helyx.Search.glob?/2`
   matches `*` (any run without `/`), `**` (any run, `/` too), `**/` (zero or
   more whole folders), `?` (one character that is not `/`), and a literal.
   Braces and classes are not part of it. A glob with no `/` matches the file
   name, so `*.ex` names every `.ex` file at any depth; a glob with a `/`
   matches the path relative to the session folder, so `src/*.ex` names the
   files of `src` only.
8. **A symbolic link to a file is searched; a symbolic link to a folder is
   not.** The walk classifies a link with `File.stat/1`: a link to a regular
   file is a file, as `read` follows it; any other link is left out, and the
   walk does not enter it. Reason: a link to a folder can point back at a
   folder above it, and a walk that followed it would not end.
9. **`grep` groups its matches by file in sorted path order.** A path is shown
   relative to the session folder (`Path.relative_to/2`), and so is an absolute
   path that the folder cannot hold. The limit and the byte budget cut the
   match list; every match found past the cut is counted, so the model learns
   how much it does not see. The last line is `3 matches in 2 files; 5 more not
   shown; 1 file skipped`, with the parts that apply. No match is a normal
   result, the text `no match`.
   A `path` that names a file is searched whatever `glob` says, and a read
   failure of that file is an error result, as `read` gives one; a file of the
   walk that cannot be read is skipped and counted.
10. **`find` returns files, never folders, sorted, relative to the session
    folder.** The limit and the byte budget cut the list, and a count line says
    how many paths were found: `3 of 5 paths shown; 2 more not shown`. No match
    is the text `no match`, as for `grep`.

## Interface changes

- `Helyx.Tool.Grep`: the tool `grep`; `concurrent?/0` is `true`. Arguments:
  `pattern` (required), `path` (optional; a file or a folder; the session folder
  by default), `glob` (optional), `ignore_case` (optional, default `false`),
  `context` (optional, 0 to 5 lines, default 0), `limit` (optional, 1 to
  `max_grep_limit/0`, default `default_grep_limit/0`).
- `Helyx.Tool.Find`: the tool `find`; `concurrent?/0` is `true`. Arguments:
  `glob` (required), `path` (optional folder; the session folder by default),
  `limit` (optional, 1 to `max_find_limit/0`, default `default_find_limit/0`).
- `Helyx.Search`: the helper. Public for the tools and the tests:
  `grep/2`, `find/2`, `glob?/2`, `walk/4`, and the bound functions that this
  doc names.
- `Helyx.Search.Glob`: the glob matcher, `@moduledoc false`, split from the
  helper for the 400-line rule of `AGENTS.md`; `Helyx.Search.glob?/2`
  delegates to it.
- `Helyx.Tool.Args`: the schema keyword `additionalProperties`, a boolean, on
  an object. With `false`, an argument key outside `properties` is an error,
  `"<key> is not an argument"`. A value that is not a boolean, or the keyword
  on a type that is not an object, raises at the first call, as an unknown
  keyword does. Both new tools declare `false`. A tool that does not declare it
  keeps its arguments, unknown keys included, as before.
- `CodingAgent.plugins/0` adds the two tools.
- The tests of the bundled tools that list the tool names and the concurrent
  tools add the two names (`plugins/bundled/test/helyx/tool/bundled_names_test.exs`,
  `plugins/bundled/test/helyx/tool/read_test.exs`).
- `docs/features/coding-agent.md`, "Out of scope": `grep` and `find` are no
  longer out of scope; `ls` stays out.

## Replaced mechanism

None. The tools are new; `bash` stays. The `additionalProperties` keyword is
new to `Helyx.Tool.Args`, and no tool declared it before, so every existing
tool checks its arguments as before.

## Bounds

| What | Bound | Over the bound | Where |
| ---- | ----- | -------------- | ----- |
| `pattern` | a string of at most `Helyx.Search.max_pattern_bytes/0` bytes; required | an error result; nothing runs | `parameters/0` of `Helyx.Tool.Grep`, checked by `Helyx.Tool.Args` |
| a pattern that does not compile | a regular expression that `Regex.compile/2` accepts | an error result with the text of the compile error | `Helyx.Search.grep/2` |
| `glob` | a string of at most `Helyx.Search.max_glob_bytes/0` bytes | an error result | `parameters/0` of both tools |
| `context` | an integer from 0 to `Helyx.Search.max_context_lines/0`; a missing or `null` value is 0 | an error result | `parameters/0` of `Helyx.Tool.Grep` |
| `grep` `limit` | an integer from 1 to `Helyx.Search.max_grep_limit/0`; a missing or `null` value is `Helyx.Search.default_grep_limit/0` | an error result | `parameters/0` of `Helyx.Tool.Grep` |
| `find` `limit` | an integer from 1 to `Helyx.Search.max_find_limit/0`; a missing or `null` value is `Helyx.Search.default_find_limit/0` | an error result | `parameters/0` of `Helyx.Tool.Find` |
| `path` | no bound of its own; the arguments of a call are bounded by the provider path (10,485,760 bytes of one response in `Helyx.Provider.OpenAI.Events`), and `read` gives its path no bound either | a path that no file has: an error result for the named path, a skipped entry in the walk | `Helyx.Search.grep/2`, `find/2` |
| an argument key outside `properties` | none | an error result, `"<key> is not an argument"` | `Helyx.Tool.Args` with `additionalProperties: false` |
| entries visited by a walk | `Helyx.Search.max_entries/1`, 50,000; a test sets `:grep_max_entries` or `:find_max_entries` of `helyx_plugins` | the walk stops; the result says so | `Helyx.Search.walk/4` |
| the wait of a search | `Helyx.Search.deadline_ms/1`, 10,000 ms; a test sets `:grep_deadline_ms` or `:find_deadline_ms` of `helyx_plugins` | the walk stops, or `Task.shutdown/2` kills the search Task; the result says so | `Helyx.Search.grep/2`, `find/2` |
| a file that `grep` reads | `Helyx.Search.max_file_bytes/0` bytes of valid UTF-8 | skipped and counted | `Helyx.Search.grep/2` |
| one shown line | `Helyx.Search.max_line_bytes/0` bytes, cut at a character boundary | the line is cut and ends in `…` | `Helyx.Search` |
| the result text | `Helyx.Search.budget/0` bytes of matches, paths, and lines, under `Helyx.Message.max_result_bytes/0` with room for the last lines | later matches and paths are not shown, and the last line counts them | `Helyx.Search.grep/2`, `find/2` |
| a path shown to the model | valid UTF-8; a byte that is not becomes U+FFFD | the name is shown repaired | `Helyx.Search` |

The counts of a last line are `10` digits or fewer: `max_entries/1` and the
matches of one walk are below 4,294,967,296, and one match is at most
`max_line_bytes/0` plus its path. The last lines fit the room that `budget/0`
holds back from `Helyx.Message.max_result_bytes/0`.

## Ownership

The search runs in a Task of the tool call. Its result goes to the tool, and a
deadline ends it.

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| search Task | `Helyx.Tool.Grep.run/2` and `Helyx.Tool.Find.run/2` | the tool Task, linked | its result goes to the tool | the link ends it with the tool Task | `Task.shutdown/2` with `:brutal_kill` at the deadline, and the hands kill the tool Task as for any call |
| file handle of a read | `Helyx.Text.read_file/2`, in the search Task | the search Task | closed before the read returns | the OS closes it when the Task dies | the OS closes it when the Task is killed |
| folder handle of a listing | `File.ls/1`, in the search Task | the search Task | closed before the call returns | the OS closes it when the Task dies | the OS closes it when the Task is killed |

No process, port, process group, socket, or temp file is created.

## Out of scope

- The ignore rules of the repository (a `.gitignore` walk, and `git ls-files`):
  the fixed list of decision 3, and a later ticket if a product needs it.
- Braces and character classes in a glob; a glob that names folders.
- A `ls` tool (`docs/features/coding-agent.md` keeps it out of scope).
- Binary files: `grep` skips and counts them, and no tool searches inside them.
- A page of a cut result: the model narrows `path`, `glob`, or `pattern`, as
  `read` narrows with `offset`; `grep` has no offset.
- Content search of a file that the walk does not reach, such as a member of an archive.
- The render in the TUI and the client kit: the tools return text, and the TUI
  shows a tool result as it shows any other.
