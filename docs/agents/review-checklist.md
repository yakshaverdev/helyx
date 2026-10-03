# Review checklist

Invariants the review axes check on every diff. Add one when a review or a PR comment finds a defect that a checklist line would have caught. The failure-path brief in the ship skill names the probe categories; the lines here are the invariants the probes must not break.

## Specs and bounds

- The feature doc states the bound of every input, buffer, and wait, or says "unbounded, ticket #N". The spec axis checks that table against the diff.
- Any numeric limit in code has a property test or, at minimum, tests at the limit, one under, one over, and a multibyte case.
- Every `ponytail:` marker names a ticket. Judge whether the debt is safe to ship, not only whether it is recorded.
- A design decision that the tools research (`docs/research/coding-tools.md`, issue #17) covered cites it in the feature doc, so the spec axis can check the design against how codex, opencode, and pi behave.
- Every external resource in the diff (OS process, process group, port, file handle, socket, temp file) has a row in the feature doc's ownership table. A row whose release path dies with its owner is a design flag the spec axis raises (ADR 0004).
- A change that replaces a mechanism has the "Replaced mechanism" section of `docs/features/TEMPLATE.md`. The spec axis checks it against the code. A part or a test of the old mechanism with no row is a finding. Source: reviews 1 and 2 of the provider design (2026-10-02), where a contract derived from a summary missed the guarantees of the start ask, the interrupt order, and the completion wait.
- A change that removes or moves doc text (a moduledoc trim, a doc split) checks each sentence that stays, with its `@doc` neighbours, against the code without the removed text. A removed qualifier can turn a kept sentence false. Source: #306 (2026-10-02), where the trim removed the connected steer rules and left `steer/2` promising a delivery that a connected turn does not guarantee.
- A doc sentence that says how a state changes (a message closes, a call ends, a request is answered), or what a value holds, is checked against every writer of that state: search the code for each function that writes it, not only the path the change touches. A second writer makes an exclusive claim false. Source: #307 (2026-10-03), where the context rule said only `message_end` closes an assistant message, and `Server.take_steer/2` closes it too.

## Boundaries

- Each input is checked at its boundary (see `AGENTS.md`, "Elixir guidelines"). The spec axis names the boundary of every new input.
- A library function that parses boundary input can raise on some inputs, not only return an error. `OptionParser.parse/2` raises `ArgumentError` on `-=` (#148). At the boundary, contain the exceptions of such a parser by name, and probe it with generated input, not only with the cases a reviewer thinks of.
- Inner code has no defensive handling: no fallback clause, `{:error, _}` return, `rescue`, or repair for a state that no caller can make. A reviewer reports such code as a finding, with every caller and the upstream check (`file:line`). A repeated check is a finding only when the earlier check still proves the same property; a documented safety check and a check of a limit that a transformation, an accumulation, or elapsed time introduces are not findings.
- Later code uses the checked value. A new read of the source is a finding only when its value is used under the earlier check with no check of its own.
- A boundary check rejects the smallest unit that permits safe continuation. The failure path names what one bad value destroys, and the feature doc states each case where missing identity, damaged structure, or an unresolved resource requires a larger failure.
- A public plugin entry (a tool's `run/2`, a provider's `stream/3`) is a boundary for all of its arguments, because code outside the hands and the session can call it.
- A finding needs a reachable input: its reproduction enters through a boundary. Source: the boundary review of 2026-09-26.
- A value from outside that confirms a safe state (an empty queue, a finished command, a ready context) is matched on the exact safe value. A missing field, `null`, a wrong type, or an unknown status takes the unsafe path: stop or fail. The failure-path review sends each of these to every such check. Source: the Codex findings of #199 (a nil context), #200 (a missing `still_queued`), and #201 (a command completed with `inProgress`), one class three times; no mechanical check can know which state is safe, so the rule is here.

## Races and resource ownership

- A race is closed structurally or stated as a hole. It is never accepted by window size or by who the caller is today. An open race is written in the ownership table as "open, ticket #N", the same vocabulary as an unbounded input.
- Two findings on one mechanism stop the patching. The next round fixes the mechanism, not the path. The first question is whether the mechanism can be deleted, for example a stored value that can be derived on read (#269).
- A `receive` loop with a deadline checks the deadline before each `receive`. A matching message in the mailbox wins over `after`, even with a timeout of 0, so a sender that never stops keeps the loop past its deadline. The failure path queues messages past the deadline and checks that the loop acts on it. Source: the Codex round 1 finding of #11.
- A Task that a shutdown must end at once does not trap exits. With the trap on, a shutdown is a message: it waits behind every message queued before it and behind any work or blocking call that runs with the trap on. A trap that a graceful stop needs (the Codex interrupt) has its wait stated in the feature doc. Source: the four findings of #167 on the trap of the Claude Code stream.
- Every resource has a release path that works when its owner dies (ADR 0004): inside the VM through links to the owner, at the OS boundary through the port watchdog. The resource is still held with the hands, with `Helyx.Tool.hold/1`, before the external work starts, because delivery and cancel wait until it is gone.
- A test that monitors a process it just spawned uses `spawn_monitor/1`. With `Process.monitor(spawn(...))` the process can exit before the monitor is set, and the `:DOWN` reason is `:noproc`. Source: the Codex round 1 finding of #170.
- A wait that orders two effects (a barrier: act only after another process has handled something) has no timeout that falls through to the act. A timeout there is a path that breaks the order. The failure-path brief states the order as an invariant, and the review treats each timeout, error, and exit of the wait as a path of it. A bound on such a wait comes from the monitor of the process it waits for, or is stated as "unbounded, and accepted". Source: the Codex round 1 finding of #189.

## Events

- Every `message_start` gets a `message_end` on the same turn, on success and on failure.
- Every turn ends with `agent_end`, on success and on failure.
- Sequence numbers increase by one per event within a session instance, with no gaps. Every event and every snapshot carry the instance id (#204).
- A rule that a snapshot equals the fold of the events is checked against every path that writes to the transcript: for each write, the live fold and the snapshot create cells by the same rule, or the difference is a stated limit. `grep` the callers of the transcript writers (`record_result`, `abort_open_calls`), not only the paths the ticket names. Source: #163, Codex round 2 (an external turn, now a connected turn, that ends normally records `aborted` results for calls that never started; the live fold ignores the result event, and the snapshot makes a closed cell).

## Sessions and turns

- A failure in a turn never crashes the session. The turn fails, the session accepts the next prompt.
- A message from a Task that is no longer current never touches the session.
- A stream that ends without a terminal event fails the turn.
- A partial assistant message from a failed turn is not added to the transcript.
- An id of outside state (a harness session, a remote job) is reused only when that state has received everything it needs, for example the whole replay. The failure path builds the table of the id's life (stored, first use, completed) crossed with abort, steer, failure, a Task crash, and a restart, and tests each cell. Source: the Codex round 1 finding of #10.

## Plugins and Core

- Bad configuration returns `{:error, reason}` from `start_link`; it never raises. This includes a module that does not exist, two plugins for a single-mode interface, no plugin for a required one, and two providers with one id.
- Core knows no interface by name except the fixed list it checks at boot.

## Inputs from plugins

- Plugin output that breaks the contract (a provider event, action, or reply that the contract does not allow) gets one generic answer: the boundary check fails, the provider process stops, and the turn fails. No special handler or special error result per case; a test checks the generic failure path. Bounds against resource growth and data loss are safety, not behaviour, and stay.
- A case gets its own handler only with evidence that a real provider or program does it: a research note, an observed run, or a bug report. The finding names the evidence. A finding that asks for a case-specific handler of output that no real provider shows is rejected with this rule, and the review record says so. A finding that the generic failure path does not fire (the output reaches session state, or the provider process does not stop), a race between Core processes, and a broken safety bound stay findings. When a test exists only for such a case, deleting the test and its handler is a valid fix. Source: owner direction of 2026-10-03 (#360).
- A value from a plugin is checked by shape before it reaches a process that holds state. Match the whole tuple or struct, never elements by index.
- Providers are compiled into the node. Shape is checked; individual field values are not.
- A plugin value that ends a deadline (a prepare Task that cancels its armed kill, a reply that a phase waits for) is checked before the cancel. An invalid value takes the failure path of that deadline. A value equal to a sentinel of the waiting state (nil for "not ready yet") never reaches that state, or the phase waits with no deadline. The failure-path review sends nil, a forged struct, and a wrong field type through each plugin callback of the change. Source: the Codex round 1 finding of #199.
- One bad tool call from a provider is rejected alone when it has an id: a provider sends arguments that are not a JSON object as their raw text (`Helyx.Provider`), `Helyx.Session.Stream.check/1` gives the call `%{}` and a rejection reason, and the call gets an error result. The text and the other calls of the message stay. Only a call with no id fails the turn. No transcript entry, session file entry, or tool result holds the raw text; Core's own errors name such a call with `%{}` (#380).
- A plugin callback that runs in the caller of a session start or resume (a tool spec callback, a tool's `check/0`), and any plugin code that the check of its value runs (a JSON encoder of a plugin struct), has its raise, throw, and exit contained and returned as `{:error, reason}`. A provider `id/0` runs once, at Core start, in the caller of `Helyx.Core.start_link/1`, is contained there, and a bad or a shared id stops the start (#169); `Helyx.Provider.find/2` calls no plugin code. Source: the Codex round 1 finding of #142.
- A plugin check that can fail a session start or resume runs in the `with` chain of `Session.start/2` and `Session.resume/2`, before the sessions directory is read and before any file or process is created. The tool `check/0` runs there through `Helyx.Tool.check_available/1`, right after `Helyx.Tool.specs/1`; the hands do not run it. Accepted (#104): `resume/2` resolves the model ref (`Helyx.Provider.find/2`) after `Helyx.Session.File.resume/2`, because the ref comes from the file, so a failed provider check on resume can leave a repaired file. The repair only appends a missing newline or cuts a last line that can never parse, and every later resume makes the same change, so nothing is lost. Source: #150 and its round 2 failure-path review.

## Tools and hands

- A tool Task that dies without a result still produces a tool result, with `is_error` true.
- The tool calls of one assistant message run one at a time, in call order, so no two touch the working directory at once.
- Truncation holds for trailing blank lines, for a line exactly at the byte limit, and cuts on a character boundary.
- Two tools with one name are rejected at session start.
- Truncation holds when one line is larger than the byte limit.
- A `rescue error in ErlangError` also catches the exceptions that the BEAM normalizes, such as `SystemLimitError` and `ArgumentError`, and these have no `:original` field. Format a caught exception with `Exception.message/1`, never with a field of one exception type (#141).
- A tool never loads unbounded input or buffers unbounded output. A model-chosen path can be a device or a huge file; a command can write forever. A result that dropped output says so.

## Tests

- A change to how a test waits keeps what the test checks. When a poll or a sleep is replaced by an event wait, the exit condition of the old poll (for example `map_size(state.held) >= n`) stays as an assertion after the new wait. For each removed wait, the spec axis names the assertion that replaces its exit condition, and a mutation that breaks that condition still fails the test (#264).
