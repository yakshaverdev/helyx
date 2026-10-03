defmodule Helyx.Test.CodexFake do
  # A fake `codex` in `bin` speaks the JSON-RPC lines of `codex app-server`
  # in the shapes that `docs/research/codex-app-server.md` records. Run N
  # saves its arguments to `args.N` and each line it reads to `stdin.N`;
  # for the K-th request or notification of method M it runs `on.N.M.K`,
  # or else `on.N.M` (M with `/` as `_`), which prints the canned answer;
  # `out` prints a file with the id "@" set to the request's id.
  # It exits at the end of its input. The dispatcher of `test_helper.exs`
  # runs it from `bin` next to the session's working directory, so no test
  # changes PATH. The tests that do are in `Helyx.HarnessIO.PathTest`.
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [start_supervised!: 1]
  import Helyx.Test.Events
  import Helyx.Test.HarnessDriver

  alias Helyx.{Message, Session}
  alias Helyx.Provider.{Codex, Fake}

  # The thread ids are macros, so that a pattern can use them.
  defmacro tid, do: "019a0000-0000-7000-8000-000000000001"
  defmacro fresh_tid, do: "019a0000-0000-7000-8000-000000000002"

  def done, do: %{status: "completed", aggregatedOutput: "out", exitCode: 0}

  # A tool item that never completes. It is not a command, because an open
  # command at the turn's end stops the provider process.
  def search, do: %{type: "webSearch", id: "b", query: "x", status: "inProgress"}

  @fake """
  #!/bin/sh
  d=$(dirname "$0")
  out() { sed 's/"id":"@"/"id":'"$i"'/g' "$@"; }
  n=$(( $(cat "$d/count" 2>/dev/null || echo 0) + 1 ))
  echo $n > "$d/count"
  for a in "$@"; do printf '%s\\n' "$a"; done > "$d/args.$n"
  while IFS= read -r line; do
    printf '%s\\n' "$line" >> "$d/stdin.$n"
    mi=$(printf '%s\\n' "$line" | perl -MJSON::PP -ne '$o = decode_json($_); print(($o->{method} // "") =~ tr{/}{_}r, " ", $o->{id} // "")')
    m=${mi%% *}; i=${mi#* }
    if [ -n "$m" ]; then
      k=$(( $(cat "$d/count.$n.$m" 2>/dev/null || echo 0) + 1 ))
      echo $k > "$d/count.$n.$m"
      if [ -f "$d/on.$n.$m.$k" ]; then . "$d/on.$n.$m.$k"
      elif [ -f "$d/on.$n.$m" ]; then . "$d/on.$n.$m"; fi
    fi
  done
  """

  def setup_fake(%{tmp_dir: tmp}) do
    bin = Path.join(tmp, "bin")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "codex"), @fake)
    File.chmod!(Path.join(bin, "codex"), 0o755)

    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Codex, Fake]})
    work = Path.join(tmp, "work")
    File.mkdir_p!(work)
    %{core: core, bin: bin, work: work, sessions: Path.join(tmp, "sessions")}
  end

  # Protocol lines

  def j(map), do: JSON.encode!(map)

  def note(tid, method, params),
    do: j(%{method: method, params: Map.put(params, :threadId, tid), emittedAtMs: 1})

  def thread(tid), do: %{id: tid, cwd: "/work", model: "gpt-6-luna", path: "/r.jsonl"}

  def delta(tid, item, text),
    do: note(tid, "item/agentMessage/delta", %{turnId: "turn1", itemId: item, delta: text})

  def started(tid, item), do: note(tid, "item/started", %{turnId: "turn1", item: item})
  def completed(tid, item), do: note(tid, "item/completed", %{turnId: "turn1", item: item})

  def message(tid, id, text) do
    item = %{type: "agentMessage", id: id, phase: "final_answer"}

    [
      started(tid, Map.put(item, :text, "")),
      delta(tid, id, text),
      completed(tid, Map.put(item, :text, text))
    ]
  end

  def command(id, fields),
    do:
      Map.merge(
        %{type: "commandExecution", id: id, command: "/bin/zsh -lc ls", cwd: "/work"},
        fields
      )

  def usage(tid) do
    note(tid, "thread/tokenUsage/updated", %{
      turnId: "turn1",
      tokenUsage: %{last: %{inputTokens: 12, outputTokens: 7}, total: %{inputTokens: 12}}
    })
  end

  def turn_end(tid, status, error \\ nil) do
    note(tid, "turn/completed", %{
      turn: %{id: "turn1", items: [], status: status, error: error && %{message: error}}
    })
  end

  # A turn: the turn/start answer, then `lines`.
  def turn(tid, lines) do
    [
      j(%{id: "@", result: %{turn: %{id: "turn1", status: "inProgress"}}}),
      note(tid, "turn/started", %{turn: %{id: "turn1", status: "inProgress"}}) | lines
    ]
  end

  # The same lines as the program's turn `id`.
  def as_turn(lines, id), do: Enum.map(lines, &String.replace(&1, ~s("turn1"), ~s("#{id}")))

  # Writes the answer of run `n` to `method`: `lines`, then `tail` as shell
  # code. With `k`, only to its `k`-th request.
  def on(bin, n, method, lines, tail \\ "", k \\ nil) do
    name = String.replace(method, "/", "_") <> if(k, do: ".#{k}", else: "")
    File.write!(Path.join(bin, "out.#{n}.#{name}"), Enum.map(lines, &[&1, "\n"]))
    File.write!(Path.join(bin, "on.#{n}.#{name}"), ~s(out "$d/out.#{n}.#{name}"\n) <> tail)
  end

  def initialize(bin, n),
    do:
      on(bin, n, "initialize", [j(%{id: "@", result: %{userAgent: "fake", platformOs: "macos"}})])

  # A run that starts thread `tid`, takes the replay, and runs `lines` as
  # its turn.
  def fresh(bin, n, tid, lines, tail \\ "") do
    initialize(bin, n)

    on(bin, n, "thread/start", [
      j(%{id: "@", result: %{thread: thread(tid)}}),
      j(%{method: "thread/started", params: %{thread: thread(tid)}})
    ])

    on(bin, n, "thread/inject_items", [j(%{id: "@", result: %{}})])
    on(bin, n, "turn/start", turn(tid, lines), tail)
  end

  def reply(tid, text),
    do: message(tid, "msg_1", text) ++ [usage(tid), turn_end(tid, "completed")]

  def stdin(bin, n) do
    bin
    |> Path.join("stdin.#{n}")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
  end

  def request(bin, n, method), do: Enum.find(stdin(bin, n), &(&1["method"] == method))
  def runs(bin), do: bin |> Path.join("count") |> File.read!() |> String.trim()

  def start(ctx, model \\ "codex/gpt-6-luna") do
    {:ok, session} =
      Session.start(ctx.core, model: model, cwd: ctx.work, sessions_dir: ctx.sessions)

    {:ok, _, _} = Session.subscribe(session)
    session
  end

  def prompt(session, text) do
    :ok = Session.prompt(session, text)
    collect_until(:turn_end)
  end

  # The callbacks, driven in the test process as the provider loop drives
  # them, without Core. `Helyx.Tool.hold/1` does nothing here.

  # Shell code that writes `lines` to stdout in the background once the
  # test calls `go/1`.
  def lines_file(bin, name, lines),
    do: File.write!(Path.join(bin, name), Enum.join(lines, "\n") <> "\n")

  def after_go(bin, name, lines) do
    lines_file(bin, name, lines)
    ~s{(while [ ! -f "$d/go" ]; do sleep 0.02; done; out "$d/#{name}") &\n}
  end

  def go(bin), do: File.write!(Path.join(bin, "go"), "")

  def connect(work, opts \\ []), do: Codex.init("m", [], [cwd: work] ++ opts)

  def ask(state, request) do
    from = make_ref()
    {:ok, actions, state} = Codex.request(request, from, state)
    {from, actions, state}
  end

  def turn_on(state, id \\ "t1"),
    do: ask(state, {:turn, id, %Helyx.Context{messages: [Message.user("go")]}})

  def turn_ended?(actions) do
    Enum.any?(actions, fn
      {:event, _turn_id, {kind, _}} -> kind in [:done, :error]
      _action -> false
    end)
  end

  def events(actions),
    do: for({:event, "t1", event} <- actions, do: event) ++ for({:stop, _} = s <- actions, do: s)

  # Runs one turn on a new program, and gives its events, then the stop, if
  # any.
  def run_direct(messages, work) do
    {:ok, state} = connect(work)
    {_from, actions, state} = ask(state, {:turn, "t1", %Helyx.Context{messages: messages}})
    {actions, state} = pump(Codex, state, actions, &turn_ended?/1)
    if not match?({:stop, _}, List.last(actions)), do: close(state)
    events(actions)
  end

  # Ends the program, so it has read every line that it was sent.
  def close(state) do
    {from, [], state} = ask(state, :close)
    assert {[{:reply, ^from, :ok}], _state} = pump(Codex, state, [], replied?(from))
  end
end
