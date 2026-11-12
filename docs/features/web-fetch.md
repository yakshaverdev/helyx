# Web fetch

## Goal

The user asks the agent about a library. The agent calls `web_fetch` with the URL of the docs page and reads the page as text. Today it has only `bash` with `curl`, which returns raw HTML that fills the context.

The tool is bundled: `Helyx.Tool.WebFetch` in `plugins/bundled/lib/helyx/tool/web_fetch.ex`, named `web_fetch`, registered in the coding agent. The coding tools that this one is measured against have a fetch tool in their default set (`docs/research/coding-tools.md`, "Default tools").

Decisions, each with its reason:

- **A tool, not `curl` through bash.** The result is text of a bounded size and a known content type, in one call, with no shell quoting.
- **A download bound, a result cut, a redirect cap, and one deadline.** The server process serves one user and holds the session for the whole turn. A page must not read unbounded bytes, hold the call without end, or loop on redirects. A page that tells the model to fetch another URL gets the same rules at every hop.
- **Every address of the host is checked before the request.** The server can run on a machine that has private services: a page on a loopback address, a metadata endpoint on a link-local address. The refused ranges are the clauses of `public?/1` in the tool: loopback, private, link-local, the shared range that an overlay network uses, unique-local, multicast, reserved, and an IPv4 address of those in an IPv6 form. A page can tell the model to fetch them. A redirect target is checked again, by the same rules.
- **HTML becomes text with a hand-written scanner.** A parser is a dependency with its own release cycle and its own defects, for a read that keeps no structure. The scanner keeps the text and the link targets, and drops what the model cannot use. The title of the page is a line of the text; the head is not dropped as a whole, because a page may leave out its close tag. A block tag, `br`, and a newline of the source start a line, and a run of blank lines becomes one, so a code block of the page keeps its lines.
- **Another content type is an error.** The model reads text. A PDF or an image fills the context with bytes, and the tool cannot cut them at a character boundary.
- **`utf-8` and `latin1` only.** A wrong decode gives text that reads as correct and is not. Another charset is an error that names it, and the model can fetch another page or read it with bash.

## Interface changes

- New Tool plugin `Helyx.Tool.WebFetch`: `name/0` is `"web_fetch"`, `concurrent?/0` is `true`. It starts and ends with the session like `Helyx.Tool.Read`; it has no `check/0`.
- `parameters/0` holds `url` (a string of 1 to `max_url_bytes/0` bytes, required) and `max_bytes` (an integer from 1 to `max_bytes/0`, default `max_bytes/0`), with `additionalProperties: false`.
- `run/2` returns `{:ok, text}` or `{:error, text}` for every case the doc states below; the arguments are checked at the entry with `Helyx.Tool.Args`.
- The schema uses `additionalProperties: false`, which `Helyx.Tool.Args` checks (`docs/features/search-tools.md`).
- New internal module `Helyx.Tool.WebFetch.Text`, `@moduledoc false`: the HTML text scanner.
- The application env key `:web_fetch_req_options` of `helyx_plugins` holds a keyword list for `Req` and for the resolver, as `:openai_req_options` does for the provider. The key `:resolver` is the test seam: a function of the host and `:inet` or `:inet6` that answers `{:ok, addresses}` or `{:error, reason}`; it is removed before the list goes to `Req`. A value that is not a keyword list, or a resolver that is not a function of two arguments, is an error result.

## Replaced mechanism

none. This adds a tool. `bash` with `curl` keeps working.

## Bounds

| What | Bound | Over the bound |
| ---- | ----- | -------------- |
| `url` argument | 1 to `max_url_bytes/0` bytes; scheme `http` or `https`, and a host | an error result; the host is not resolved and nothing is fetched |
| `max_bytes` argument | 1 to `max_bytes/0`; missing or `null` is the default, `max_bytes/0` | an error result; nothing is fetched |
| a redirect target | the same rules as `url`, its byte bound included, and every address of its host is checked | an error result; the target is not fetched |
| redirects of one call | `max_redirects/0` | an error result |
| body read of one hop | `download_bytes/0`, enforced in the stream of the body, so a larger body never sits in memory | the read stops at the bound, and a line after the text says that the body was cut |
| wait of one call | `deadline_ms/0` from the start of the call, for the host lookup and for every hop: each hop gets the time that is left as its pool, receive, and request limit, and the call runs in a Task that is killed at the deadline, which bounds a connect too | an error result; the connection closes |
| content type | `max_type_bytes/0`, in the first line and in the error text that names a type | cut at the bound |
| text after the conversion | `max_bytes/0`, cut on a character boundary with the marker `[… cut …]` of `Helyx.Message.cut_result/1` | cut, with the marker; the whole result fits `Helyx.Message.max_result_bytes/0` |
| text of a status of 400 or more | `max_error_bytes/0` of the text | cut at the bound |
| latin1 to UTF-8 | the conversion can double the bytes of the body, so at most twice `download_bytes/0` before the result cut | the result cut bounds it |
| HTML to text | never longer than the body it reads: a tag or an entity becomes a shorter or equal text | none |

The header line, the text, the marker, and the note of a cut body fit `Helyx.Message.max_result_bytes/0` together, whatever the URL and the content type, and a module attribute raises at compile time when they do not.

A body of exactly `download_bytes/0` bytes is read whole, and one byte more is cut at the bound. A character that the download bound splits is dropped from the text only when the body was cut; a body that is not valid UTF-8 on its own is an error result.

The expiry of the deadline has no test, because a test would wait the whole limit. A test reads the receive and request limits that a hop gives `Req` instead, and checks that each is a positive time within `deadline_ms/0`. The hop sets no connect option, because `Req` starts one pool for each value of one, and the time that is left differs in every call.

The rules of the request:

1. The method is `GET`. `accept` is `text/markdown, text/plain, text/html`, and `accept-encoding` is `identity`, so the download bound counts the bytes that the page holds and no decoder runs over them. A body that a server compresses anyway is not text that the tool can read.
2. `Req` follows no redirect (`redirect: false`) and retries nothing (`retry: false`), so the tool follows at most `max_redirects/0` itself, checks each target, and the deadline counts one chain.
3. The statuses 301, 302, 303, 307, and 308 are redirects; a redirect with no `location` is an error result. Another status is the answer.
4. The content type is read first, then the charset, then the status: a body that the tool cannot read as text is an error whatever its status, and a status of 400 or more is an error with its text.

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| TCP connection and its socket | the Finch pool of `Req`, a process that Req starts in its own supervision tree (no name of ours) | the Finch pool process, checked out to the Task of the tool call | checked in at the end of the response | the pool removes and closes the connection when the Task that holds the checkout dies | the abort kills the Task, so the same path as a crash |
| Task of the chain of one call | the tool call (linked) | the tool call | the chain ends, and the Task with it; at the deadline the tool call kills it | it dies with the tool call | it dies with the tool call |
| Task of the host lookup | the Task of the chain (linked) | the Task of the chain | the lookup ends, and the Task with it | it dies with the tool call | it dies with the tool call |

The tool holds no handle with `Helyx.Tool.hold/1`: a request ends with its Task, and a socket that outlives a killed Task is closed by the pool (`NimblePool`, `handle_info/2` of `{:DOWN, ...}`).

## Accepted holes

- The host is resolved once and every address is checked, but the request lets `Req`/`Finch` resolve the host again, because a pool is keyed by scheme, host, and port and cannot take a fixed address per call without its own connection. A second DNS answer can name another address than the one that was checked, so an attacker who controls the DNS answer and the page gets one race. The same holds for a redirect target and for a connection that the pool reuses. A hostname is therefore checked, not pinned.
- A connection that a pool already holds was made by an earlier request to that host, under the address rules of that request.
- The deadline counts the lookup and the hops. `Finch` checks the request limit before each read of a chunk, and its own doc calls it a best effort limit for HTTP/1; a body that keeps arriving is bounded by the download bound, not by the clock.
- A page whose charset is another than `utf-8` or `latin1` is an error, also when the body is ASCII and would decode as it is.

## Out of scope

- Cheaper reads of a page: a `text/markdown` negotiation for a page that serves one, and a cache of a URL in the session.
- JavaScript, and a body that a script builds.
- A PDF, an image, or another content type that is not text. A converter is its own ticket.
- A per-host rule, a proxy, and a cookie jar.
- A page that the model must authenticate to read.
