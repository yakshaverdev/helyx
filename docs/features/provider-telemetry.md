# Provider attempt telemetry

## Goal

A turn of the user stalls for a minute and then fails, at night, while
`helyx serve` runs. Nothing records why. This feature records one event for
each HTTP attempt of a model call, so the reason is in a file the next
morning:

```sh
jq 'select(.status == 429)' ~/.helyx/sessions/telemetry.jsonl
```

The output names three 429 answers with their waits, then a `give_up`.

The event is the public seam. A product attaches its own reporter or
exporter to `[:helyx, :provider, :attempt]`, and it needs nothing else. The
recorder is a small bundled helper that a product starts, so a server keeps
the events with no collector. The event is the contract; the file is one
reporter of it.

The rules that shape it:

- A plugin emits `:telemetry` at its own wire seam, where it already sees
  the attempt: `Helyx.Provider.OpenAI` at each `Req.post/1`. The plugin
  names its event and its metadata.
- Core emits no event and knows no event name. An event is not an
  interface, and Core stays free of a provider concept.
- No content leaves the provider: no prompt, no output, no tool argument,
  no header, no key, no request or response body. Every value is an id, a
  count, a status, an error atom, or a wait.

## Interface changes

### The attempt event

`[:helyx, :provider, :attempt]`, one event per call of `Req.post/1` in
`Helyx.Provider.OpenAI`, emitted after the retry decision and before any
wait.

Measurements:

| Key | Value |
| --- | ----- |
| `duration` | integer, native time units, from just before `Req.post/1` to its return: the response headers or the transport error |

Metadata, all keys always present:

| Key | Value |
| --- | ----- |
| `provider` | the endpoint id (`endpoint.id`), such as `"opencode-go"` |
| `model` | the model string of the call |
| `attempt` | 0 for the first request, then 1, 2, 3 |
| `status` | the HTTP status integer, or nil for a transport error |
| `error` | nil, or for a transport error its reason when it is an atom (`:timeout`, `:econnrefused`, `:closed`), else `:other` |
| `decision` | `:ok` (status 200), `:wait` (a retry follows), `:too_long` (the server asked for a wait over the limit), `:give_up` (the retries are used up), `:fail` (no retry for this answer) |
| `wait_ms` | the wait in milliseconds for `:wait` and `:too_long`, else nil |

`duration` is taken with `System.monotonic_time/0`. `Req.post/1` returns at
the response headers, because the request streams `into: :self`, so the
duration is the time to the headers or to the transport error, never the
time of the body.

### `Helyx.Telemetry.Recorder`

A bundled helper in `plugins/bundled`, not a plugin: it implements no
interface and has no registration entry. A product starts it.

- `start_link(opts)`: `opts[:name]`, default `Helyx.Telemetry.Recorder`.
  It traps exits and attaches one handler with `:telemetry.attach_many/4`,
  id `{__MODULE__, name}`, to `events/0`. It starts closed: no file.
- `events/0`: `[[:helyx, :provider, :attempt]]`. The one list of recorded
  events; a later slice adds names here.
- `open(server \\ __MODULE__, path, max_bytes)`: opens the file, a
  `GenServer.call`. A file that is open is closed first.
- `close(server \\ __MODULE__)`: closes the file. The recorder stays, and
  drops the lines that follow.
- `path(server \\ __MODULE__)`: the open file, or nil.
- `line(event, measurements, metadata)`: one JSON object and `"\n"`, pure
  and `@doc false`. It writes `ts`, `event`, `ms`, and the seven metadata
  keys of the table above, and no other key: a later event that carries
  content cannot leak through the recorder by accident.
- `handle_event/4`: builds the line in the caller, then writes it with a
  `GenServer.call` of `@call_ms`, inside a catch of the exit. A handler must
  never raise, because `:telemetry` detaches a handler that raises.

The server writes in its own process. When closed, it drops the line. When
`size + bytes` passes `max_bytes`, it closes the file, renames it to
`<path>.0` (the rename replaces an older `.0`), opens a new file, and
writes the line. A write error drops the line and logs one warning per
open, with the reason.

### The coding agent

`CodingAgent.Application` starts the recorder before `CodingAgent.Servers`,
so the children stop in reverse order and the server stops before the
recorder.

`CodingAgent.Serve.serve/1` opens `<data folder>/telemetry.jsonl` with
`CodingAgent.LogFile.max_bytes/0` after it removes a stale server file and
before it starts Core. Only the process that holds the lock of the data
folder opens the file, so two servers never write one file. An error prints
one line, `helyx: telemetry is off: <reason>`, and the server goes on:
telemetry never stops a server. `CodingAgent.Serve.stop/4` closes the file
before it releases the lock.

## Replaced mechanism

None. The retry behaviour does not change: every branch of `delay/2` and
`fail_or_retry/3` acts as it did, and the event reads the decision that
they already take. The attempt becomes `post/3` and `fail_or_retry/5` to
carry the provider and the model, and the decision is computed once and
passed to both the event and the branch.

## Bounds

| What | Bound | Over the bound |
| ---- | ----- | -------------- |
| wait of a model call for one write of the recorder | `Helyx.Telemetry.Recorder` (`@call_ms`), 1,000 ms: the longest that a model call waits on a slow disk; past it the line is dropped and the call goes on | the line is dropped, and the attempt goes on |
| size of the telemetry file | `CodingAgent.LogFile.max_bytes/0`, the one cap that the app gives each log file, passed by `CodingAgent.Serve` to `open/3`: the app keeps one cap for `server.log` and for `telemetry.jsonl` | the file rotates to `<path>.0` before the write that passes the cap |
| older files of the data folder | one, `<path>.0`, as for `server.log`; a rotation replaces it | the oldest lines are lost |
| cap that `open/3` accepts | 4,096 bytes to 1 GiB (`@min_max_bytes`, `@max_max_bytes`): under a kilobyte is no history, and over a gibibyte is not a log file | `{:error, :einval}` |
| size of one line | a few hundred bytes: every value is an id, a number, or a code | no bound is needed; a line over the cap rotates the file before its write, and the file can pass the cap by one line |
| messages in the mailbox of the recorder | one for each waiting caller: every write is a call, and at most 64 sessions run per Core, each with one model call at a time | the caller waits its `@call_ms` |
| path that `open/3` accepts | absolute, and a regular file or not there | `{:error, :einval}` for a relative path, `{:error, :not_regular}` for a folder, a FIFO, or another type |
| warnings of a write error | one for each `open/3`, not one for each line | the lines after the first are dropped with no line |

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| the telemetry file handle | `open/3`, in the recorder | the recorder process | `close/1` from `CodingAgent.Serve.stop/4`, or `terminate/2` at the stop of the application | the process dies, so the descriptor closes; the file stays with its lines | n/a |
| the telemetry handler | `init/1`, with `:telemetry.attach_many/4` | the `:telemetry` handler table, which names the recorder | `terminate/2` detaches it | the table keeps the entry; its call finds no process and the handler returns `:ok` | n/a |

A handler of a recorder that was killed stays in the table. Its calls find
no process, so an event is dropped and no caller fails. A start of a
recorder under the same name fails on `:already_exists` rather than attach a
second handler. The crash of the recorder is a crash of the supervision
tree of the app, which is the failure that a person must see.

## Out of scope

- Events of the harness providers (Claude Code, Codex): a later slice.
- Events for the stream after the headers: the time to the first token and
  the stream end.
- A reader of the file in a report, and an exporter to a collector.
- Turn and tool spans, which need the session feed.
- Any change under `lib/` (Core) and the wire protocol.
