# Domain review of Helyx Core

Date: 2026-10-12. Master at 2de609b. Report only: no code changed, no tickets opened.

Scope: `lib/helyx/` and its seam to `plugins/bundled/lib/`. `apps/coding_agent/` was used as evidence only. Trust-boundary items of `2026-09-26-boundary-review.md` were out of scope unless they regressed.

Method: one concept map built by a script, six read-only lenses in parallel (Opus), a merge into 22 candidate findings, three adversarial reviewers on three models (Opus, Fable, Sonnet), then lead judgment. Each finding cites `file:line` and a proof level: 2 = points at the line, 3 = walked step by step, 4 = ran real code. Every level-4 proof in "Act on" was run again by the lead on master.

## 1. Summary

The core domain is strong at the plugin seam. Core names no plugin, harness, program, or wire protocol. No bundled plugin calls another. The helpers follow ADR 0005. Every item of the 2026-09-26 baseline is done or withdrawn, with no regression.

The domain is weakest in three places:

1. **Limits and value types that the contract does not state.** A Helyx tool result over 64 KiB fails the whole turn, and Core breaks this limit with text that it makes itself. Turn errors send pids, refs, and stacktraces to clients, which ADR 0006 calls a defect.
2. **One fact stored twice in the session server.** The provider pid is in two slots, the resume label is a count that a repair must shift, and the resume request is stored on the turn instead of the process. The last one is a live bug.
3. **Glossary drift.** About 16 entries disagree with the code, among them Follow-up, Compaction, Context, Turn, and Session.

## 2. Concept map

The owner of each domain concept, as the code is today. "Two owners" marks a finding.

| Concept | Owner | Other modules that read or write it | Decided in |
|---|---|---|---|
| Plugin table, interface modes | `Helyx.Core`, `Helyx.Core.Plugins` | `Helyx.Interface` (declaration) | no ADR (see M12) |
| Session handle and public API | `Helyx.Session` | `Session.Server` | ADR 0006 |
| Session instance state | `Session.Server.State` | every `Server.*` module | `session-lifecycle.md` |
| Turn data | `Session.Turn` | TurnLoop, Records, ToolRuns (disjoint fields) | `session-lifecycle.md` |
| Turn lifecycle | `Server.TurnLoop` | `Server.Wait` (Turn to Wait), `Server` (routing) | `session-lifecycle.md:9` |
| Steer and follow-up queue | `Session.Queue` (pure), `Server.Steering` (only writer) | TurnLoop, Wait | ADR 0007, `session-lifecycle.md` |
| Abort of the queues | two owners: `Queue.end_turn`, `Wait.finish`, `Wait.abort` | `TurnLoop.abort` | M7 |
| Transcript | `Server.Records` (only writer) | `Session.Transcript` (queries, repair) | ADR 0001 |
| Session file, entry | `Session.File` (+ `Branch`, `Codec`) | Records | ADR 0001 |
| Events, `seq`, subscribers | `Server.Events` | all emitters call `emit` | ADR 0006 |
| Snapshot | `Server.Events` + `Turn.snapshot/1` | `Queue.counts/1` | ADR 0006 §3 |
| Provider process | `Session.ProviderProcess`, `ProviderRequest` (replies, deadlines) | two slots: `State.conn` and `Wait.provider` | ADR 0007 (M4) |
| Provider event check | `Session.Stream.check/1` | none | boundary review |
| Context per call | `TurnLoop` (base), `Stream.prepare/4` (plugins) | providers | `one-provider-path.md` |
| Tool set | `Helyx.Session` at start | `State.tool_specs`, `State.tool_modules`, `Hands.State.tools` | `2026-09-26-tool-specs.md` (M12) |
| Tool runs | `ToolQueue` (decides), `ToolRuns` (effects), `Hands` (runs) | `Provider.Loop` (order on the provider side) | ADR 0003 |
| Tool result size | two owners: `Session.Stream` (Core), `Helyx.Text` (plugin) | Hands, `Provider.Loop` | M2 |
| Resume id label | `Records.resume/3` | `File.Branch`, `Transcript.repair/2`, `Turn.resumed` | M3, N1 |
| Messages, content blocks | `Helyx.Message` | `File.Codec` maps each field | ADR 0001 |
| Model ref | `Helyx.ModelRef` | Session, Records, Transcript | glossary |

The table comes from these commands, run from the repo root at 2de609b:

- `mix xref graph --format plain`, in the root, in `plugins/bundled`, and in `apps/coding_agent`. These graphs show file dependencies inside each project only.
- A script that lists each Core module with its kind (struct, behaviour, process, internal) and the files in Core, plugins, and apps that reference it, through full names and aliases. It also counts glossary words and plugin-only words (harness, program, wire, tui, openai, claude, codex, perl, watchdog, mcp) per file.

<details>
<summary>concept_map.py (run with <code>python3 -I concept_map.py &lt;repo&gt;</code>)</summary>

```python
import re, sys
from pathlib import Path

root = Path(sys.argv[1])
core_files = sorted((root / "lib").rglob("*.ex"))
plugin_files = sorted((root / "plugins/bundled/lib").rglob("*.ex"))
app_files = sorted((root / "apps").glob("*/lib/**/*.ex"))
rel = lambda p: str(p.relative_to(root))

modules = {}
for f in core_files:
    src = f.read_text()
    for m in re.finditer(r"^\s*defmodule ([\w.]+)", src, re.M):
        kinds = [k for k, hit in [("struct", "defstruct" in src), ("behaviour", "@callback" in src),
                 ("process", re.search(r"use (GenServer|Agent|Task|Supervisor)", src)),
                 ("internal", "@moduledoc false" in src)] if hit]
        modules.setdefault(m.group(1), (rel(f), kinds))

def aliases(src):
    out = {}
    for m in re.finditer(r"alias ([\w.]+)\.\{([^}]+)\}", src):
        for part in (p.strip() for p in m.group(2).split(",")):
            out[part.split(".")[-1]] = f"{m.group(1)}.{part}"
    for m in re.finditer(r"alias ([\w.]+)(?:,\s*as:\s*(\w+))?\s*$", src, re.M):
        out[m.group(2) or m.group(1).split(".")[-1]] = m.group(1)
    return out

def refs(f):
    src = f.read_text()
    found = {n for n in modules if re.search(re.escape(n) + r"(?![\w])", src)}
    found |= {full for short, full in aliases(src).items()
              if full in modules and re.search(r"(?<![\w.])" + re.escape(short) + r"[.{]", src)}
    return found - {m.group(1) for m in re.finditer(r"^\s*defmodule ([\w.]+)", src, re.M)}

users = {n: {"core": [], "plugins": [], "apps": []} for n in modules}
for group, files in (("core", core_files), ("plugins", plugin_files), ("apps", app_files)):
    for f in files:
        for n in refs(f):
            users[n][group].append(rel(f))

for n in sorted(modules):
    f, kinds = modules[n]
    print(n, f, ",".join(kinds), *(f"{g}={len(users[n][g])}" for g in ("core", "plugins", "apps")))

terms = re.findall(r"^\*\*(.+?)\*\*:", (root / "CONTEXT.md").read_text(), re.M)
for t in terms + ["harness", "program", "wire", "tui", "openai", "claude", "codex", "perl", "watchdog", "mcp"]:
    pat = re.compile(r"\b" + re.escape(t.lower()).replace(r"\ ", r"[ _]") + r"s?\b", re.I)
    print(t, sum(bool(pat.search(f.read_text())) for f in core_files),
          sum(bool(pat.search(f.read_text())) for f in plugin_files))
```

</details>

## 3. Act on

### A1. The tool result size limit has two owners, and Core breaks it with its own text (M2)

**Evidence.**
- Core sets `@max_tool_result_bytes 65_536` at `lib/helyx/session/stream.ex:13-17`.
- A comment there derives this number from a plugin constant, `Helyx.Text.@max_bytes 51_200` (`plugins/bundled/lib/helyx/text.ex:8-9`). Nothing else ties the two numbers together.
- Since #300, every Helyx tool result goes back through `Provider.Loop` as a provider `{:tool_result, ...}` event (`lib/helyx/provider/loop.ex:115,215-219`). The check at `stream.ex:185-190` then fails the whole turn.
- The hands accept any binary from `run/2` (`lib/helyx/session/hands.ex:347-351`).
- The hands also make their own text with no size limit: `"unknown tool: #{call.name}"` (`hands.ex:344`), `Exception.format/3` (`hands.ex:354`), and `inspect(reason)` (`hands.ex:251`).
- `Helyx.Tool` (`lib/helyx/interfaces/tool.ex:2-10`) states no limit.

**Proof: level 4.** The lead ran this again on master.

```
external tool returns 70,000 bytes:
  {:tool_execution_end, %{bytes: 7, role: :tool_result, is_error: true}}
  {:turn_end, %{error: {:tool_result_too_large, 70000, 65536}, outcome: :error}}
tool raises with a long message:  %{error: {:tool_result_too_large, 70426, 65536}, outcome: :error}
model calls an unknown tool with a long name: %{error: {:tool_result_too_large, 70014, 65536}, outcome: :error}
```

The user sees the turn fail, and the tool output is lost. A model that makes up a long tool name ends the turn. The error blames the provider.

**Models that agreed:** all three. Opus and Fable found the cases where the hands make the text, with level-4 proofs.

**Remedy.**
1. Make the limit part of the `Helyx.Tool` contract. It is a rule that every tool and every provider needs, so it belongs in Core (AGENTS.md "Project").
2. Cut every result once, in `Hands.outcome/3` (`hands.ex:255`). Its comment already says "Every result leaves the hands through here". Keep the head of the text and add a notice. This covers `run/2` output and the text that the hands make.
3. Keep the check at `stream.ex:185-190` for results that a harness program makes.
4. Delete the comment arithmetic at `stream.ex:13-16`. `Helyx.Text` asserts at compile time that its cut fits under the Core limit.
5. Update `docs/features/tool-text-out-of-core.md:26-37` and `docs/features/coding-agent.md:67`. After the change, a result over the limit no longer fails the turn.

### A2. Turn errors send raw plugin terms to clients (M1, N3 of Sonnet, N2 of Opus)

**Evidence.**
- `Wait.end_data/1` emits the reason as `error: term` in `turn_end` (`lib/helyx/session/server/wait.ex:48`).
- `Records.close_cut/3` emits it in `message_end` (`lib/helyx/session/server/records.ex:101,104`).
- `Helyx.Event` documents both fields as `term` (`lib/helyx/interfaces/event.ex:22-23,28-29`).
- The reasons come from these places:
  - `{:bad_return, other}`: `provider_process.ex:63,82,102,116`
  - `{:bad_action, action}`: `provider_process.ex:175`
  - stacktraces: `loop.ex:193,262-271` and `turn_loop.ex:124`
  - hands exit reasons: `hands.ex:244-247`
- Only `cap_integers` is applied to these reasons.
- ADR 0006 §2 and its Consequences say that a contract value with a pid, ref, function, or module is a defect.
- The TUI turns the term into text itself (`plugins/bundled/lib/helyx/tui/view_model.ex:270-278`).

**Proof: level 4.** The lead ran this again on master.

```
turn_end data: %{error: {:bad_action, {:reply, #Reference<0.3639144180.3290169345.211200>, :ok}}, outcome: :error}
event data holds a ref/pid/fun: true
```

A remote transport cannot encode this event. Each client must make its own text from an unknown term.

**Models that agreed:** all three. Fable notes that tests pin the current term shape (`test/helyx/session/provider_process_test.exs:212-300`, `test/helyx/provider/loop_test.exs:233-245`), so the remedy changes them.

**Remedy.**
1. Add one function in `Server.Events` that maps a reason to capped text for the event, and logs the full term. `Wait.cleanup_notice/2` (`wait.ex:89-95`) already uses this pattern.
2. Use the function for `turn_end` and for `message_end`.
3. `Helyx.Event` documents `error: String.t()`.
4. Delete `ViewModel.error_text/1`.
5. Keep the `cap_integers` calls before the inspect.
6. Add a test that folds all emitted events and rejects any pid, ref, or function.
7. Q1 asks who owns the text.

### A3. The resume request is stored on the turn, not on the provider process (N1 of Opus; live bug)

**Evidence.**
- `Turn.resumed` is set only by the turn that connects a provider process (`lib/helyx/session/server/turn_loop.ex:178,192`).
- A reused process skips it (`turn_loop.ex:174-175`).
- `Records.resume/3` reads it to compute `lost` (`records.ex:122`).
- If the connecting turn ends before the provider sends `{:resume, id, cut}`, the next turn has `resumed: nil`. An abort during a slow harness start is one such case.
- Codex sends `{:resume, ...}` at the first turn of a fresh thread (`codex.ex:485`). Its `init/3` falls back to a new thread when the resume fails (`codex.ex:322`).

**Proof: level 4.** The lead ran this again on master. The provider was started with `id-261`, and it later started fresh with `id-293`:

```
init resume_id: "id-261"
turn_end: %{outcome: :aborted}
turn 3: process 2 reused
provider_session: %{cut: 0, provider: "ext", resume_id: "id-293", lost: false}
```

The user presses Esc while Codex starts, then prompts again. The provider lost its session, but the TUI does not show "lost its own session" (`view_model.ex:166-169`).

**Models that agreed:** Opus only. The finding is new in Phase 4, and the lead proved it.

**Remedy.**
1. Move `resumed` from `Turn` to `ProviderConn`.
2. `connect/1` sets it. `Records.resume` reads it from `conn` and clears it.
3. This also removes one field from `Turn` (see C1).

### A4. The resume label stores a count that the repair must shift (M3)

**Evidence.**
- `{resume_id, messages_before}` is computed when a session runs (`records.ex:121`) and when the file is read (`lib/helyx/session/file/branch.ex:119-131`).
- `Transcript.repair/2` then shifts the count (`lib/helyx/session/transcript.ex:65-84`, with bookkeeping in `walk/5` at `:90-107`).
- Only `Transcript.resumable/3` (`transcript.ex:132-143`) reads the count. It asks only whether an assistant message follows the label.
- The repair never adds or drops an assistant message.
- Five fix commits touched this mechanism. Two of them (#269, #417) fixed only the shift.

**Proof: level 4.** The lead ran this again on master over 20,000 random transcripts. It compared today's rule with "count the assistant messages before the label, no shift":

```
%{same: 16368, differ: 0, no_label: 3632}
```

**Models that agreed:** all three. Lens 6 found the same mechanism through the history of fix commits.

**Remedy.**
1. Store the number of assistant messages before the label.
2. Delete the shift and the `inserts`/`drops` accumulators.
3. `repair/2` then returns only the transcript.
4. The file format does not change, because the count is derived by position on read.

### A5. One provider process is held in two state slots (M4)

**Evidence.**
- The two slots are `State.conn` (`ProviderConn{pid, ready}`, `lib/helyx/session/server/state.ex:7-8,59-60`) and `Wait.provider` (`wait.ex:23`).
- After an interrupt (`wait.ex:52-54`) or an idle close (`turn_loop.ex:98-101`), both slots hold the same pid.
- Other paths move the pid from `conn` to `Wait.provider` (`turn_loop.ex:283-285,327-330,364-367`).
- The readers must check both slots:
  - two `provider_down` clauses (`turn_loop.ex:107-111`)
  - two `if`s (`wait.ex:74-75`)
  - `Enum.uniq` in `work/1` (`turn_loop.ex:381-382`)
  - a ledger clear that starts from four places (`steering.ex:81`, `turn_loop.ex:266,272`, `wait.ex:76`)

**Proof: level 4** (Lens 2, `slots.exs`). The pid was in both slots during an interrupt.

**Models that agreed:** all three. Opus and Fable corrected one claim. The `if`s at `wait.ex:74-75` are not always true. After `Wait.finish({:done, ...})`, or after `monitor_down`, one slot is already nil. The order of `:DOWN` and `:provider_down` is not fixed.

**Why it matters:** the provider-end path had five defects in #361 and earlier (Lens 6, C-F2). Each new handler must know which slot holds the pid in which activity.

**Remedy.**
1. Give `ProviderConn` one field `status :: :starting | :ready | :ending`.
2. Set `:ending` only on a `stop_after` answer. The `reply` slot already blocks progress while an interrupt waits for its answer.
3. Delete `Wait.provider` and `ProviderConn.ready`.
4. Make `provider_down` one clause, and make it the only caller of `Steering.provider_down`.
5. Delete the `uniq` and the branch at `steering.ex:81`.
6. Update `session-lifecycle.md:51`, which lists `provider` as a part of the wait.

### A6. ADR text that the code no longer matches (M12, M13)

**Evidence: proof level 3**, from the history of commits. Opus and Fable checked each item.

- **ADR 0003, Consequences:** "The set of available tools is reported by the hands." This is false since af73030 (#142). The session builds the tool set at start (`lib/helyx/session.ex:77-78,118-119,172-173`) and gives it to the hands (`server.ex:26-31`). `docs/reviews/2026-09-26-tool-specs.md:7-9` records the decision. Both the tool set and the perl check run on the session's node, which matters for remote hands, the reason for ADR 0003.
- **ADR 0007, Decision:** "An abort first stops and releases the turn's Helyx tool calls, then asks the program to stop". Since #361 (80bcf97) both run in parallel (`wait.ex:41-42,52-54`, `hands.ex:98-99`). `session-lifecycle.md:47` is correct.
- **ADR 0007, Consequences:** "the session mailbox ... stays unbounded (#197)". #197 (dd90d84) bounded provider sends at 10,000 (`stream.ex:22,226-236`).
- **ADR 0007** says the program ends "when the provider changes". The code closes it at every model switch (`turn_loop.ex:327-331`).
- **`Helyx.Event` moduledoc** (`event.ex:10-12`) gives the instance-drop rule to every client. The ADR 0006 revision of 2026-10-03 gives it only to a client that reconnects.
- **`wait.ex:86`** cites ADR 0006 §5, which is now "Replaced". The reply rule is in §2.

**Remedy.** Amend ADR 0003 and ADR 0007, and point each amendment to the commit or review that changed the code. The ADR 0003 amendment says: the session owns the tool set, the plugin table and the tool set are fixed after start (`session.ex:165`), the cost for remote hands, and the open #473. Fix the moduledoc and the comment.

### A7. Glossary and AGENTS.md edits (M8, M9, M10, M14, M16, M19, M21)

**Evidence: levels 2 to 4.** Section 9 lists the edits.

Two items have level-4 proofs:
- **Follow-up.** Three queued follow-ups become one turn. The lead ran this again on master: turn 2 has user "second", user "third", and one reply. `session-lifecycle.md:51` already decides "steers first". `session.ex:313` drifts the same way as the glossary.
- **The TUI.** Core rejects `Helyx.TUI` as a plugin (`{:error, {:not_a_plugin, Helyx.TUI}}`), but AGENTS.md "Project" says that user interfaces are plugins.

**Models that agreed:** all three, on the glossary part.

**Remedy.** Apply section 9. The Follow-up and Abort entries change with the queue code, in one change (decided 2026-10-12, see Q4 and C2): `session-lifecycle.md:51`, `session.ex:28,313`, and the glossary move together.

## 4. Consider

- **C1. Delete the `:context` phase (M6).**
  - `:context` equals `phase == :submitted and prepare != nil`. It is set only at `turn_loop.ex:69` and cleared only at `:235`.
  - Delete it, and match on `prepare` (sites `turn_loop.ex:59`, `steering.ex:48`, `wait.ex:53`).
  - Add `@type` to `Turn`, `Wait`, `State`, and `ProviderConn`, so that `activity` is a checked union.
  - Do not use the full tagged phase that Lens 5 proposed. Opus showed that it loses the real state `:submitting` with `pending: nil` (`turn_loop.ex:80-81`).
  - Tradeoff: a small deletion now, against types that Dialyzer can check later.
- **C2. One owner for the Abort queue rule (M7).**
  - `Queue.end_turn(_, _, false)`, `Wait.finish` (`wait.ex:38-39`), and `Wait.abort` (`wait.ex:102-103`) each do part of the rule.
  - Make the public `Queue.abort/1` drop both queues and settle the ledger. Keep a private ledger-only settle for `Queue.provider_down/1`. Delete `wait.ex:39` and the drop at `:102`.
  - Opus and Fable showed that the first remedy would drop queued steers when a provider process dies during a preparing turn (`turn_loop.ex:266`). Do not use it.
- **C3. State the per-call meaning of `Context.tools` and `Context.system` (M10).**
  - Keep the `tools` field. Two of the three reviewers showed that it is the only per-call seam (and the seam that #473 needs), and that harness programs need their tools at `init/3`.
  - Document in `Helyx.Context` and `Helyx.Provider` that both fields are what a model provider sends on this call, and that a harness may ignore them.
  - Cost that stays: `ModelContext.Default` reads the context files on every harness turn, and the harness drops the result. State it in `docs/features/context-files.md`.
- **C4. One key rule for `usage` and tool arguments (M17).**
  - Atom keys become string keys across a resume (Lens 5, level 4).
  - #488 plans a reader of usage, so keep it.
  - Make `Stream.check/1` require string keys (`stream.ex:94-99,140-153,208`), and make OpenAI emit string keys (`openai/events.ex:224-229`). See Q3.
- **C5. State the plugin-facing rules in `Helyx.Provider` (N2 of Fable).**
  - `codex.ex:448` and `openai/events.ex:212` cite the internal modules `Session.Queue` and `Session.Stream` for two contract rules: a steer is taken at most once, and an empty tool call id fails the turn.
  - Put both rules in the `Helyx.Provider` moduledoc.
- **C6. Delete the `required` interface option (M11).**
  - It works only through the hard-coded `@interfaces [Helyx.Provider]` (`core.ex:33`). Lens 4 proved this at level 4.
  - Replace it with one check in `Core.start_link`.
- **C7. No Task for a fixed error (M20).**
  - The hands start a Task only to return "unknown tool" or "no cwd" (`hands.ex:259,344-345`), and they put the atoms `:unknown` and `:no_cwd` in the module slot.
  - Answer at once, as `refuse/3` does (`hands.ex:281-284`).
- **C8. Rename the stream event and the client event to `resume_id` (M15).**
  - One fact has four names: `{:resume, ...}`, `:provider_session`, `harness_session` on disk, and `Session.resume`.
  - The client event rename costs one release under the ADR 0006 revision of 2026-10-03.
  - The disk names stay. They are already documented as an exception (`file.ex:240-241`, `branch.ex:117-118`).

## 5. Noted

- **`Helyx.Tool.hold/1`** also serves providers, but its doc says "tool" only (`tool.ex:155-175`). Fix the wording (M18).
- **`Helyx.Provider.Loop`** is Core code in the plugin name slot. AGENTS.md "Module naming" should state the exception that ADR 0002 decides (N1 of Fable).
- **`Session.start/2` and `resume/2`** repeat the same prelude (`session.ex:75-78,116-119`) (N2 of Sonnet).
- **`State.tool_modules`** is read once (`server.ex:30`). The #142 review decided it (N1 of Sonnet).
- **The name `Helyx.Session.Stream`** fits none of its three jobs. `Message.resume_id?/1` also checks provider-turn ids. Both are names only (M22).
- **Kept after the history check (Lens 6):**
  - The two provider-end signals stay, as long as `Hands.start_provider/3` blocks during releases that run inline. If one more defect lands there, question the blocking call, not the session clauses.
  - The four-state steer ledger stays. Late rejected steers and armed kills force it.

## 6. Dismissed

- **Merge the two dispatch tables of `Server` and `TurnLoop` (M5).**
  - `session-lifecycle.md:9` decides the split, and the two drop lists are disjoint.
  - The move would push `turn_loop.ex` (383 lines) over the 400-line limit.
  - Fable has a smaller idea if the `:turn_start` clause order ever causes a defect: `ProviderProcess` sends `{:provider_turn, id}` as its own message.
- **Make `Helyx.Provider.OpenAI` a `@moduledoc false` helper (M22).** All three reviewers disagreed. It is the documented root of one plugin family in one file, not code that different plugins share.
- **A new ADR for compaction (M9) and for the fixed plugin table (M12).** No decision is made now. The glossary fix and the ADR 0003 amendment cover them.
- **Rename `{:interrupt, _}` and the release mode `:cancel` to "abort" (M14).** `:cancel` also runs at a failed or done turn, and it is in the public `release/3` contract of every tool. Only the glossary terms stay (section 9).
- **Drift in three parts of M13:**
  - `session-lifecycle.md:14` is about the Core loop, and that is correct.
  - The ADR 0004 revisions for #10 and #11 are dated history.
  - ADR 0007 already voids the ADR 0002 "Helyx tools are not visible" text.
- **Stop storing `usage` (M17, option 1).** #488 needs it.

## 7. Baseline status

`2026-09-26-boundary-review.md`: every item is done or withdrawn, and no item regressed. Lens 6 confirmed each one with a commit or `file:line`.

| Items | Status | Evidence |
|---|---|---|
| A1, A2, A4, A5, A6 | done | 0fab320 (#143) and others |
| A3 | done | 0fab320; ADR 0006 rev (#406) put back a catch-all for unknown types |
| A7 | withdrawn | kept, as decided |
| B | done | 160961d (#144) |
| C1, C2, C3 | done | 52eaa9c, af73030 + 9a026c5, fc2903c |
| D1, D2, D3, D4 | done | 68a69bc, 23a759d (later obsolete by #265), e4a6793 |
| E1, E2, E3 | done | 0fab320 |
| T0 to T8 | done | c9fec48 through e4a6793 |

`2026-09-26-core-cleanup-plan.md`:

| Item | Status |
|---|---|
| Task 1 (`Session.Stream`) | done (097df82), then reshaped by #300 |
| Task 2 (tool text out of Core) | done (0cd5c41). A1 above is a new problem at the seam it made. |
| Task 3 (split `Helyx.Session`) | done (3878618, f414549); #320 and #321 went further, split by state owner |
| Task 4 (folders) | done (6cd12b0) |
| Task 5 (`kind` flag) | done (0abf7e3), then replaced by #265 and #300 |
| G1 to G5 | done |
| G6 | withdrawn; two of the three functions were deleted later |
| "Document that an AGENTS.md edit takes effect at the next context build" | **open**: missing from `model_context/default.ex:11-30` and `docs/features/context-files.md` |

## 8. ADR conflicts

- **Contradicts ADR 0006 (Consequences): turn errors carry pids and refs.** The ADR is right and the code is wrong (A2). The fix opens one question in ADR 0006 §2: who turns an error into text. §2 puts this map "in a transport", and no transport exists (Q1).
- **ADR 0003 is false since #142 (A6), and it is worth reopening for remote hands.** Today the tool set and the perl check run on the session's node, but a remote hands needs them on its own node. Amend now. Decide again when remote hands come.
- **ADR 0007 is stale on the abort order and the mailbox bound (A6).** These are doc-only fixes.
- **AGENTS.md contradicts ADR 0006 and the code: "user interfaces" are plugins (A7).** The TUI is a client, and Core rejects it as a plugin.
- **AGENTS.md "Module naming" contradicts ADR 0002: `Helyx.Provider.Loop` sits one level below an interface but is not a plugin.** State the exception in AGENTS.md.

## 9. Glossary changes (proposed, not applied)

- **Follow-up:** "A message for after the current turn. Each follow-up opens its own turn, in the order it was sent. Steers that the turn did not take open one turn together, before any follow-up." This changes the code: today all queued messages open one turn.
- **Abort:** "Ending the current turn now. A failed turn ends the same way. The queued steers and follow-ups leave the queue and go back to the client." This changes the code: today the queues are dropped (`wait.ex:39`, `session.ex:28`). See C2.
- **Session:** "One conversation with one agent, named by its session id and stored in its session file. Each start of its process is a session instance." Move "owns the transcript, the queues, the current turn" to Session instance.
- **Turn:** "The work from one turn start to its turn end: the provider works on one submission until its terminal event. A session runs one turn at a time." Move "repeat model calls" to Model provider. Add **Model call**: "One request to the model and its answer. A turn of a model provider holds one or more model calls." Never name a field `num_turns`.
- **Transcript:** "The ordered messages of a session. Append-only." Delete "and session entries" and "record".
- **Compaction:** "Shrinking the context of one provider call so it fits the model. The transcript does not change." Change the comment at `file.ex:21`.
- **Context:** "What a provider sees on one call: a system prompt, messages, and tool specs. The session builds it from the transcript, and the model context and compaction plugins can change it. A harness provider may use only the messages."
- **Harness provider:** "... runs its own loop and its own tools, and can ask Helyx to run Helyx tools."
- **Hands:** add "and hosts the provider process".
- **Interface:** "single: at most one plugin. multi: any number." Delete "a public API that products call", or limit it to some interfaces.
- **Client:** add "A bundled client, such as the TUI, implements no interface."
- **Entry:** replace "session record" with "session entry".
- **New terms:** Provider process, Provider id (durable, because resume ids are keyed by it), Model (the part after the slash), Prompt (the user messages that open a turn), Snapshot, Stream event, Terminal event, Helyx tool request, Withdraw (the provider takes back one Helyx tool request), Interrupt (the provider part of an abort).
- **Remove implementation details** at `CONTEXT.md` lines 12, 16, 46, 64, 68, 76, 117: module names, callbacks, option keys, and atoms.
- **In Core moduledocs**, replace "API provider" with "model provider" (`provider.ex:10`, `loop.ex:3,6`, `session.ex:18`).

## 10. Questions for the owner

❓ **Q1 - Who turns a turn error into text?** A provider breaks its contract, and the turn fails. Today the TUI gets a raw Elixir term and prints `inspect` of it. After the fix, should the user see text that Core wrote, or text that each transport writes? ADR 0006 §2 says a transport makes the start-error text, but no transport exists.

➡️ Core writes it, in one function in `Server.Events`, for both `turn_end` and `message_end`. The log keeps the full term. Every client then shows the same words, and a remote transport has nothing to encode. Amend ADR 0006 §2 to match. The reason: the ADR rule "every value is data" can then be checked in one place in Core.

---

❓ **Q2 - What does the user see when a tool returns too much text?** An external tool, a crash message, or a made-up tool name gives more than 64 KiB. Today the whole turn fails. Options:
- (a) The call gets the head of the text and a notice "output cut at N bytes", and the turn goes on.
- (b) The call gets an error result "output too large", and the turn goes on.

➡️ (a). The bundled tools already cut this way (`Helyx.Text`). So the user and the model see the same behaviour for every tool, and the model keeps the useful start of the output.

---

❓ **Q3 - Should token usage survive a resume in the same shape?** After a resume, the token numbers come back with string keys, and each provider uses its own key names. #488 plans a footer with tokens and cost.

➡️ Yes. Make the boundary accept string keys only, and do #488's "one usage key set" in the same change. The reason: the footer can then read one shape, live and after a resume.

---

❓ **Q4 - Are the glossary edits of section 9 right as a set?** In particular, the change to Follow-up keeps today's behaviour: all queued messages become one turn. The other way is one turn for each follow-up.

➡️ **Decided 2026-10-12:** change the behaviour. Steers that the turn did not take open one turn together, first. Then each follow-up opens its own turn, in order. The reason: text typed while the agent works is a steer, and it reaches the running turn, so a correction does not need the batch. A follow-up is an explicit request for after the turn, so it gets its own answer, its own turn end, and its own point to abort. `Queue.drain/1` (`queue.ex:67`) makes the change. The glossary Follow-up text, `session-lifecycle.md:51`, and `session.ex:313` change in the same commit. The other section 9 edits stand as a set. Turn keeps its meaning, and the glossary names the inner unit "model call".

## 11. Sources

| Agent | Model | Output |
|---|---|---|
| Lens 1, glossary against code | Opus | 16 findings |
| Lens 2, ownership and overlap | Opus | 5 findings |
| Lens 3, Core purity at the plugin seam | Opus | 4 findings |
| Lens 4, interface depth | Opus | 4 findings and a reader-load table |
| Lens 5, types and data shapes | Opus | 4 findings |
| Lens 6, ADRs, history, baseline | Opus | 9 findings and the baseline tables |
| Reviewer A | Opus | 22 verdicts, 2 new findings |
| Reviewer B | Fable | 22 verdicts, 2 new findings |
| Reviewer C | Sonnet | 22 verdicts, 3 new findings |

**Proof scripts.** They ran with `cd plugins/bundled && MIX_ENV=test mix run --no-start <script>`, and they were kept in the session scratch folder, not in the repo:

| Script | Finding |
|---|---|
| `big_tool.exs` | A1 |
| `crash_text.exs` and `big_raise.exs` | A1 |
| `ref_in_event.exs` and `leak.exs` | A2 |
| `lost_flag.exs` | A3 |
| `resume_count.exs` and `unshifted.exs` | A4 |
| `slots.exs` | A5 |
| `followups.exs` | A7 |
| `usage.exs` | C4 |

**Skills** whose method the review used: `domain-modeling`, `codebase-design`, `grilling` (Pocock); `how`, `why`, `blast-radius`, `interrogate`, `thermo-nuclear-code-quality-review`, and the principles model-the-domain, boundary-discipline, foundational-thinking, minimize-reader-load, type-system-discipline, subtract-before-you-add, redesign-from-first-principles, build-the-lever (pstack).

## 12. Decisions (2026-10-12)

The owner and the lead went through each finding, one at a time. Before each decision, the lead checked how other agent harnesses handle the same case. The reasons below are Helyx's own.

| Finding | Decision | Ticket |
|---|---|---|
| A1, Q2, C7 | One function scrubs, cuts on a character boundary, and adds a notice. The whole result fits the limit. The hands and `Stream` both call it, so a too-large result never fails the turn: a harness model already has the full text, and only Helyx's copy is cut. Fixed errors are answered without a Task. | #508 |
| A2, Q1 | Core turns every error into text in one function in `Server.Events`, at most 4000 bytes. The log keeps the full term. No error code field until a client acts on the kind of error. ADR 0006 §2 is amended. | #509 |
| A3, C8 | `resumed` moves to `ProviderConn`, because the resume id belongs to the process. The events are renamed to `resume_id`, now, while only the bundled TUI reads them. | #510 |
| A4 | The label counts assistant messages, and the shift is deleted. Branching does not need more: the label is an entry on the branch, the count is derived per branch, and the fork rule (#282) drops labels at a fork. Entry ids replace the count when branching puts ids on messages. | #511 |
| A5, C1 | `ProviderConn.status` replaces the second slot. `:context` is deleted, and the session structs get field types. After #510. | #512 |
| C2, A7, Q4 | `Queue.abort/1` owns the abort rule, and the dropped texts go back to the client: the composer gets them in queue order, then the draft. Leftover steers open one turn together, then each follow-up opens its own turn. The reason: text typed during work is a steer and reaches the running turn, so a correction does not need the batch, and a follow-up is a separate request. The glossary Follow-up and Abort entries change in the same commit. After #512. | #513 |
| A6, A7, C3, C5, Noted | Docs only: ADR 0003 and 0007 updates, section 9 except Follow-up and Abort, "turn" keeps its meaning and the inner unit is a "model call", the TUI is a client, provider rules in `Helyx.Provider`, and the ModelContext cost on harness turns recorded as known debt with its trigger. | #514 |
| C6 | Delete the `required` option. Core checks for one provider directly. | #515 |
| C4, Q3 | Folded into #488: a `Helyx.Usage` struct, checked at the plugin boundary and on read from disk. Tool arguments keep string keys. | #488 |

Not acted on: a model provider replays aborted and failed assistant messages (`plugins/bundled/lib/helyx/provider/openai.ex:112-114`). No API failure or bad answer is observed, so no handler is added. If such messages are ever left out, each tool call goes with its paired result.
