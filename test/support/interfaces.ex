defmodule Helyx.Test.Single do
  @moduledoc false
  use Helyx.Interface, mode: :single

  @callback name() :: String.t()
end

defmodule Helyx.Test.Multi do
  @moduledoc false
  use Helyx.Interface, mode: :multi

  @callback name() :: String.t()
end

defmodule Helyx.Test.SingleA do
  @moduledoc false
  @behaviour Helyx.Test.Single
  def name, do: "single-a"
end

defmodule Helyx.Test.SingleB do
  @moduledoc false
  @behaviour Helyx.Test.Single
  def name, do: "single-b"
end

defmodule Helyx.Test.MultiA do
  @moduledoc false
  @behaviour Helyx.Test.Multi
  def name, do: "multi-a"
end

defmodule Helyx.Test.MultiB do
  @moduledoc false
  @behaviour Helyx.Test.Multi
  def name, do: "multi-b"
end

defmodule Helyx.Test.ModelContext do
  @moduledoc false
  # Marks the context so a provider can show it was built.
  @behaviour Helyx.ModelContext

  @impl true
  def build(context, opts), do: %{context | system: "built for #{opts[:cwd]}"}
end

defmodule Helyx.Test.Compaction do
  @moduledoc false
  # Appends to the system prompt so tests see it ran after model context.
  @behaviour Helyx.Compaction

  @impl true
  def compact(context, _opts), do: %{context | system: "#{context.system}, compacted"}
end

defmodule Helyx.Test.NoInterface do
  @moduledoc false
  def name, do: "none"
end

defmodule Helyx.Test.ProviderOther do
  @moduledoc false
  # A second provider with its own id, so a test can switch between two
  # provider modules. Every model answers "from other".
  use Helyx.Provider.Loop

  @impl true
  def id, do: "other"

  @impl true
  def stream(_model, _context, _opts) do
    {:ok, [{:text_delta, "from other"}, {:done, %{stop_reason: :end_turn, usage: %{}}}]}
  end
end

defmodule Helyx.Test.BadId do
  @moduledoc false
  # A provider whose `id/0` is "bad_id" until the calling process puts a
  # mode under `:bad_id`. Then it raises, throws, exits, or returns the
  # value, so the value "test" makes it a twin of Helyx.Test.Provider.
  use Helyx.Provider.Loop

  # The bad results are the point of this provider.
  @dialyzer {:nowarn_function, id: 0}
  @impl true
  def id do
    case Process.get(:bad_id) do
      nil -> "bad_id"
      :raise -> raise "no id"
      :throw -> throw(:no_id)
      :exit -> exit(:no_id)
      other -> other
    end
  end

  @impl true
  def stream(_model, _context, _opts), do: {:ok, []}
end

defmodule Helyx.Test.Provider do
  @moduledoc false
  # A provider whose model name selects a stream shape, so session tests can
  # exercise streams that end badly.
  #
  #   "ok"         one delta, then done
  #   "gate.<name>" stops at the gate <name> (`Helyx.Test.Gate`), then
  #                streams as "ok"
  #   "empty"      an empty stream, no terminal event
  #   "crash"      one delta, then the stream raises
  #   "throw", "exit"  the stream throws or exits with :boom
  #   "exit_normal"  the stream ends its process with a :normal signal
  #   "self_halt"  an enumerable that halts by itself on a text delta
  #   "bad_event.<name>" the gate <name>, a message end, which only a
  #                harness may send, then the gate again
  #   "overrun"    a delta, done, then a raise if pulled further
  #   "error_tail" an error event, then a raise if pulled further
  #   "garbage"    one event that is not a stream event
  #   "raw_bytes"  a text delta that is not valid UTF-8
  #   "raw_call"   a tool call whose name is not valid UTF-8
  #   "bad_stop"   done with a stop reason outside the file format's set
  #   "harness_event" a message end, which only a harness may send
  #   "notice"     text, a notice, more text, then done
  #   "bad_args"   a tool call whose arguments the file format cannot hold
  #   "recover"    a first turn the file cannot hold, then a clean "again" turn
  #   "wide"       a delta tuple with an extra element
  #   "tools"      the names of the tools in the context, as text
  #   "system"     the system prompt in the context, as text
  #   "bad_call"   a tool call whose name is not a string
  #   "empty_id"   a tool call with an empty id, then done
  #   "hang"       one delta, then the stream blocks forever
  #   "transcript" every message in the context as "role:text" lines
  #   "reject_<reason>" a rejected call with a reason of N bytes
  #                ("bytes_N"), of 1,024 or 1,025 bytes with 2-byte characters
  #                ("multibyte_1024", "multibyte_1025"), not valid UTF-8
  #                ("raw"), or not text ("atom")
  #
  # The models that call tools. Unless a line says otherwise, a model calls
  # its tools until the last message is a tool result, then echoes the
  # result texts so far; so a second prompt calls the tools again.
  #
  #   "blocks"     thinking, text, and a tool call; "done" after the result
  #   "loop"       calls upcase and then a missing tool
  #   "serial"     three calls to the slow tool
  #   "kill"       calls the kill tool; echoes the last message text only
  #   "binary"     calls the binary tool
  #   "rejected"   text, one good call, and one call the provider rejects
  #   "abort"      three calls to the slow tool that sleep for a minute;
  #                echoes after any tool result
  #   "stuck"      one call to the hold tool: a handle whose release waits
  #                for the gate that the first user message names, and one
  #                that stays held, a sleep of a minute; echoes after any
  #                tool result
  #   "steer"      one slow call; after any tool result, echoes the user
  #                message texts so far, so tests see which steers reached
  #                the call
  #   "steer.<name>" "steer" with one call to the gate tool of the gate
  #                <name> (`Helyx.Test.Gate`) in place of the slow call
  #   "big_int"    six calls with large integers; after the results, a done
  #                map with the large integer
  use Helyx.Provider.Loop

  alias Helyx.Message.ToolCall

  @done {:done, %{stop_reason: :end_turn, usage: %{}}}
  @tool_use {:done, %{stop_reason: :tool_use, usage: %{}}}
  @reject %ToolCall{id: "r", name: "upcase", arguments: %{}}

  # The models whose stream is a fixed list of events.
  @fixed %{
    "ok" => [{:text_delta, "ok"}, @done],
    "empty" => [],
    "garbage" => [{:text_delta, 42}],
    "raw_bytes" => [{:text_delta, <<"hi", 255>>}],
    "wide" => [{:text_delta, "hello", :extra}],
    "raw_call" => [{:tool_call, %ToolCall{id: "c", name: <<"bash", 255>>, arguments: %{}}}, @done],
    "bad_call" => [{:tool_call, %ToolCall{id: "c", name: %{}, arguments: %{}}}],
    "empty_id" => [{:tool_call, %ToolCall{id: "", name: "bash", arguments: %{}}}, @done],
    "bad_args" => [
      {:tool_call, %ToolCall{id: "c", name: "bash", arguments: %{"text" => {1, 2}}}},
      @done
    ],
    "bad_stop" => [{:text_delta, "hi"}, {:done, %{stop_reason: :refusal, usage: %{}}}],
    "notice" => [{:text_delta, "hi"}, {:notice, "heads up"}, {:text_delta, " there"}, @done],
    "harness_event" => [{:text_delta, "hi"}, {:message_end, :end_turn, %{}}, @done],
    "repeat_id" => [
      {:tool_call, %ToolCall{id: "c", name: "upcase", arguments: %{"text" => "a"}}},
      {:tool_call, %ToolCall{id: "c", name: "upcase", arguments: %{"text" => "b"}}},
      @tool_use
    ],
    # 512 2-byte characters, 1,024 bytes; then one more byte.
    "reject_multibyte_1024" => [{:rejected_tool_call, @reject, String.duplicate("é", 512)}, @done],
    "reject_multibyte_1025" => [
      {:rejected_tool_call, @reject, String.duplicate("é", 512) <> "x"},
      @done
    ],
    "reject_raw" => [{:rejected_tool_call, @reject, <<"bad", 255>>}, @done],
    "reject_atom" => [{:rejected_tool_call, @reject, :bad}, @done]
  }

  @impl true
  def id, do: "test"

  @impl true
  def stream(model, _context, _opts) when is_map_key(@fixed, model),
    do: {:ok, Map.fetch!(@fixed, model)}

  def stream("blocks", %Helyx.Context{messages: messages}, _opts) do
    if last_result?(messages),
      do: {:ok, [{:text_delta, "done"}, @done]},
      else: {:ok, blocks()}
  end

  def stream("loop", %Helyx.Context{messages: messages}, _opts),
    do:
      echo_after(messages, [
        call("c1", "upcase", %{"text" => "hi"}),
        call("c2", "nope", %{}),
        @tool_use
      ])

  def stream("serial", %Helyx.Context{messages: messages}, _opts),
    do: echo_after(messages, slow_calls([{"1", 60}, {"2", 30}, {"3", 0}]))

  def stream("binary", %Helyx.Context{messages: messages}, _opts),
    do: echo_after(messages, [call("b", "binary", %{}), @done])

  # Echoes the text of the last message only.
  def stream("kill", %Helyx.Context{messages: messages}, _opts) do
    case List.last(messages) do
      %Helyx.Message{role: :tool_result} = m ->
        {:ok, [{:text_delta, Helyx.Message.text(m)}, @done]}

      _ ->
        {:ok, [call("k", "kill", %{}), @done]}
    end
  end

  def stream("rejected", %Helyx.Context{messages: messages}, _opts) do
    bad = %ToolCall{id: "c2", name: "upcase", arguments: %{}}

    echo_after(messages, [
      {:text_delta, "Trying"},
      call("c1", "upcase", %{"text" => "one"}),
      {:rejected_tool_call, bad, "the arguments are not a valid JSON object"},
      @tool_use
    ])
  end

  def stream("abort", %Helyx.Context{messages: messages}, _opts) do
    if any_result?(messages),
      do: {:ok, echo_results(messages)},
      else: {:ok, slow_calls(for id <- ["1", "2", "3"], do: {id, 60_000})}
  end

  def stream("stuck", %Helyx.Context{messages: messages}, _opts) do
    if any_result?(messages) do
      {:ok, echo_results(messages)}
    else
      gate = Helyx.Message.text(Enum.find(messages, &(&1.role == :user)))
      arguments = %{"handles" => [%{"gate" => gate}, "keep"], "ms" => 60_000}
      {:ok, [call("1", "hold", arguments), @tool_use]}
    end
  end

  def stream("steer", %Helyx.Context{messages: messages}, _opts),
    do: steer_after(messages, slow_calls([{"1", 200}]))

  def stream("steer." <> gate, %Helyx.Context{messages: messages}, _opts),
    do: steer_after(messages, [call("1", "gate", %{"gate" => gate}), @tool_use])

  # Six calls: an integer of 400,000 digits nested in the arguments, a good
  # call whose struct has one more key with the large integer, the largest
  # permitted integer (100 digits), a good call, the large integer as a map key, and the large integer in a struct
  # that JSON encodes. After the results, the usage and one more key of the
  # `:done` map hold the large integer.
  def stream("big_int", %Helyx.Context{messages: messages}, _opts) do
    huge = huge()

    if last_result?(messages) do
      [text, {:done, done}] = echo_results(messages)
      {:ok, [text, {:done, Map.put(%{done | usage: %{input: huge, output: 3}}, :extra, huge)}]}
    else
      {:ok,
       [
         call("c1", "upcase", %{"text" => "one", "n" => [%{"deep" => -huge}]}),
         {:tool_call, Map.put(elem(call("c2", "upcase", %{"text" => "two"}), 1), :extra, huge)},
         call("c3", "upcase", %{"text" => "three", "n" => 10 ** 100 - 1}),
         call("c4", "upcase", %{"text" => "four"}),
         call("c5", "upcase", %{"text" => "five", huge => 1}),
         call("c6", "upcase", %{"text" => "six", "d" => %Date{year: huge, month: 1, day: 1}}),
         @tool_use
       ]}
    end
  end

  def stream("gate." <> gate, _context, _opts),
    do: {:ok, Helyx.Test.Gate.stream([:gate | Map.fetch!(@fixed, "ok")], gate)}

  def stream("tools", %Helyx.Context{tools: tools}, _opts) do
    {:ok, [{:text_delta, Enum.map_join(tools, ",", & &1.name)}, @done]}
  end

  def stream("system", %Helyx.Context{system: system}, _opts) do
    {:ok, [{:text_delta, system || "no system"}, @done]}
  end

  def stream("throw", _context, _opts), do: {:ok, Stream.map([1], fn _ -> throw(:boom) end)}
  def stream("exit", _context, _opts), do: {:ok, Stream.map([1], fn _ -> exit(:boom) end)}

  def stream("self_halt", _context, _opts),
    do: {:ok, fn _acc, _reduce -> {:done, {:text_delta, "orphaned"}} end}

  def stream("exit_normal", _context, _opts),
    do: {:ok, Stream.map([1], fn _ -> Process.exit(self(), :normal) end)}

  def stream("bad_event." <> gate, _context, _opts),
    do: {:ok, Helyx.Test.Gate.stream([:gate, {:message_end, :end_turn, %{}}, :gate], gate)}

  def stream("crash", _context, _opts), do: {:ok, raise_after([{:text_delta, "so far"}], "boom")}

  def stream("hang", _context, _opts) do
    {:ok,
     Stream.concat(
       [{:text_delta, "so far"}],
       Stream.repeatedly(fn -> Process.sleep(:infinity) end)
     )}
  end

  def stream("error_tail", _context, _opts) do
    {:ok, raise_after([{:error, :overloaded}], "pulled past the error")}
  end

  def stream("transcript", %Helyx.Context{messages: messages}, _opts) do
    text = Enum.map_join(messages, "\n", &"#{&1.role}:#{Helyx.Message.text(&1)}")
    {:ok, [{:text_delta, text}, @done]}
  end

  def stream("reject_bytes_" <> bytes, _context, _opts),
    do:
      {:ok,
       [{:rejected_tool_call, @reject, String.duplicate("x", String.to_integer(bytes))}, @done]}

  # First turn ends with a usage the file format cannot hold; a later "again"
  # prompt ends cleanly, so a test can prove persistence survived the first.
  def stream("recover", %Helyx.Context{messages: messages}, _opts) do
    case List.last(messages) do
      %Helyx.Message{role: :user, content: [%Helyx.Message.Text{text: "again"}]} ->
        {:ok, [{:text_delta, "recovered"}, @done]}

      _ ->
        {:ok, [{:text_delta, "hi"}, {:done, %{stop_reason: :end_turn, usage: %{"in" => {1, 2}}}}]}
    end
  end

  # The large integer in a malformed event, in an error reason of the
  # stream, and in an error reason of `stream/3`.
  def stream("wide_int", _context, _opts), do: {:ok, [{:text_delta, "hello", huge()}]}
  def stream("error_int", _context, _opts), do: {:ok, [{:error, {:oops, huge()}}]}
  def stream("refuse_int", _context, _opts), do: {:error, {:oops, huge()}}

  # A struct in place of the usage map.
  def stream("struct_usage", _context, _opts) do
    {:ok, [{:done, %{stop_reason: :end_turn, usage: %Date{year: huge(), month: 1, day: 1}}}]}
  end

  # A struct in place of the `:done` map, with the large integer in a field.
  def stream("struct_done", _context, _opts) do
    done = %ToolCall{id: huge(), name: "x", arguments: %{}}
    {:ok, [{:text_delta, "hi"}, {:done, Map.merge(done, %{stop_reason: :end_turn, usage: %{}})}]}
  end

  # A struct in place of the arguments map.
  def stream("struct_args", _context, _opts) do
    arguments = %Date{year: huge(), month: 1, day: 1}
    {:ok, [{:tool_call, %ToolCall{id: "c1", name: "upcase", arguments: arguments}}]}
  end

  def stream("overrun", _context, _opts) do
    {:ok, raise_after([{:text_delta, "kept"}, @done], "pulled past done")}
  end

  defp blocks do
    [
      {:thinking_delta, "hm"},
      {:thinking_delta, "m"},
      {:text_delta, "Listing"},
      {:text_delta, "."},
      call("call_1", "bash", %{"command" => "ls"}),
      @done
    ]
  end

  # `calls` until the last message is a tool result, then the echo of the
  # results; so a second prompt calls the tools again.
  defp echo_after(messages, calls) do
    if last_result?(messages), do: {:ok, echo_results(messages)}, else: {:ok, calls}
  end

  defp last_result?(messages), do: match?(%Helyx.Message{role: :tool_result}, List.last(messages))

  defp any_result?(messages), do: Enum.any?(messages, &(&1.role == :tool_result))

  # `calls` before any tool result; after one, the user message texts so
  # far, joined with "|", then done.
  defp steer_after(messages, calls) do
    if any_result?(messages) do
      users = for %{role: :user} = m <- messages, do: Helyx.Message.text(m)
      {:ok, [{:text_delta, Enum.join(users, "|")}, @done]}
    else
      {:ok, calls}
    end
  end

  # The tool result texts so far, joined with "|", then done.
  defp echo_results(messages) do
    results = for %{role: :tool_result} = m <- messages, do: Helyx.Message.text(m)
    [{:text_delta, Enum.join(results, "|")}, @done]
  end

  defp call(id, name, arguments),
    do: {:tool_call, %ToolCall{id: id, name: name, arguments: arguments}}

  defp slow_calls(pairs) do
    for({id, ms} <- pairs, do: call(id, "slow", %{"ms" => ms, "text" => id})) ++ [@done]
  end

  # A lazy tail that raises when pulled, so a consumer that reads past
  # `events` fails its test instead of passing silently.
  defp raise_after(events, message) do
    Stream.concat(events, Stream.map([1], fn _ -> raise message end))
  end

  defp huge, do: String.to_integer(String.duplicate("7", 400_000))
end

defmodule Helyx.Test.Tool do
  @moduledoc false
  # The callbacks every test tool shares: `name/0`, `description/0`, and
  # `parameters/0`, an object schema unless the tool gives one.
  defmacro __using__(opts) do
    parameters = Keyword.get(opts, :parameters, quote(do: %{"type" => "object"}))

    quote do
      @behaviour Helyx.Tool

      @impl true
      def name, do: unquote(opts[:name])
      @impl true
      def description, do: unquote(opts[:description])
      @impl true
      def parameters, do: unquote(parameters)
    end
  end
end

defmodule Helyx.Test.Tool.Upcase do
  @moduledoc false
  use Helyx.Test.Tool,
    name: "upcase",
    description: "Upcases text.",
    parameters: %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}}

  @impl true
  def run(%{"text" => text}, _cwd), do: {:ok, String.upcase(text)}
end

defmodule Helyx.Test.Tool.UpcaseTwin do
  @moduledoc false
  # A second tool with the same name as Helyx.Test.Tool.Upcase.
  use Helyx.Test.Tool, name: "upcase", description: "Upcases text."

  @impl true
  def run(_args, _cwd), do: {:ok, "twin"}
end

defmodule Helyx.Test.Tool.Kill do
  @moduledoc false
  # A tool whose Task dies without returning.
  use Helyx.Test.Tool, name: "kill", description: "Kills its own Task."

  # run/2 never returns; the brutal kill is the point.
  @dialyzer {:nowarn_function, run: 2}
  @impl true
  def run(_args, _cwd), do: Process.exit(self(), :kill)
end

defmodule Helyx.Test.Tool.Binary do
  @moduledoc false
  # Returns bytes that are not valid UTF-8, so tests can see the hands make
  # the result valid.
  use Helyx.Test.Tool, name: "binary", description: "Returns invalid bytes."

  @impl true
  def run(_args, _cwd), do: {:ok, <<"a", 255, "b">>}
end

defmodule Helyx.Test.Tool.Slow do
  @moduledoc false
  # Sleeps `ms` and returns `text`, so call order and finish order can differ.
  use Helyx.Test.Tool, name: "slow", description: "Sleeps, then echoes."

  @impl true
  def run(%{"ms" => ms, "text" => text}, _cwd) do
    Process.sleep(ms)
    {:ok, text}
  end
end

defmodule Helyx.Test.Tool.Hold do
  @moduledoc false
  # Holds the handles in "handles" with the hands, then sleeps "ms", so tests
  # can drive the release without an OS resource. Its release acts on the
  # handles it gets:
  #
  #   {:report, pid}  sends {:release, mode, handles} to pid
  #   {:slow, ms}     sleeps ms before the release returns
  #   %{"gate" => g}  waits for :go from the gate `g` (`Helyx.Test.Gate`)
  #   :keep           stays held
  #   {:keep, agent}  stays held while the Agent holds true
  #   :raise, :exit   the release raises or exits
  #   :bad            the release returns a handle it was not given
  #   :improper       the release returns an improper list
  #
  # "keep" and %{"gate" => g} are the forms a transcript can hold. Every
  # other handle is released.
  use Helyx.Test.Tool, name: "hold", description: "Holds handles."

  @impl true
  def run(%{"handles" => handles} = args, _cwd) do
    Enum.each(handles, &Helyx.Tool.hold/1)
    Process.sleep(Map.get(args, "ms", 0))
    {:ok, "held"}
  end

  # The improper list of `:improper` is on purpose.
  @dialyzer {:nowarn_function, release: 3}
  @impl true
  def release(handles, mode, _deadline) do
    for {:report, pid} <- handles, do: send(pid, {:release, mode, handles})
    Process.sleep(Enum.sum(for {:slow, ms} <- handles, do: ms))
    for %{"gate" => gate} <- handles, do: Helyx.Test.Gate.wait(gate)

    cond do
      :raise in handles -> raise "release failed"
      :exit in handles -> exit(:release_failed)
      :bad in handles -> [:not_given]
      :improper in handles -> [:improper | :tail]
      true -> Enum.filter(handles, &kept?/1)
    end
  end

  defp kept?(:keep), do: true
  defp kept?("keep"), do: true
  defp kept?({:keep, agent}), do: Agent.get(agent, & &1)
  defp kept?(_handle), do: false
end

defmodule Helyx.Test.Tool.HoldTwo do
  @moduledoc false
  # A second tool module with the release of the hold tool, so tests can see
  # one release Task per module.
  use Helyx.Test.Tool, name: "hold_two", description: "Holds handles."

  @impl true
  defdelegate run(args, cwd), to: Helyx.Test.Tool.Hold
  @impl true
  defdelegate release(handles, mode, deadline), to: Helyx.Test.Tool.Hold
end

defmodule Helyx.Test.Tool.HoldBare do
  @moduledoc false
  # Holds a handle but has no release/3.
  use Helyx.Test.Tool, name: "hold_bare", description: "Holds a handle it cannot release."

  @impl true
  def run(_args, _cwd) do
    Helyx.Tool.hold(:handle)
    {:ok, "held"}
  end
end

defmodule Helyx.Test.Tool.Unavailable do
  @moduledoc false
  # A tool whose check always fails, so tests can see a session start or
  # resume refuse it.
  use Helyx.Test.Tool, name: "unavailable", description: "Never available."

  @impl true
  def run(_args, _cwd), do: {:ok, ""}
  @impl true
  def check, do: {:error, "the frob is missing"}
end

defmodule Helyx.Test.FailingJSON do
  @moduledoc false
  # A value whose JSON encoder is plugin code that throws or exits.
  defstruct [:kind]
end

defimpl JSON.Encoder, for: Helyx.Test.FailingJSON do
  def encode(%{kind: :throw}, _encoder), do: throw(:boom)
  def encode(%{kind: :exit}, _encoder), do: exit(:boom)
end

defmodule Helyx.Test.Connected do
  @moduledoc false
  # A connected provider (ADR 0007) whose model name selects its answers.
  # It reports each callback to the test process that registered itself as
  # `controller(core)`: `{:conn, :init, pid, {model, tools, opts}}`, and
  # `{:conn, kind, pid, request}` for each request. It holds the handle
  # `{:report, controller}` at init; its release sends `{:release, mode,
  # handles}` to the controller. At init it also links a process that
  # never ends by itself and sends `{:linked, pid, linked}`.
  #
  #   "echo"             a turn answers :ok, then "echo:<system>|<last user
  #                      text>" and done; an interrupt and a close answer :ok
  #   "hang"             a turn answers :ok and sends "so far"; the message
  #                      `{:finish, turn_id}` sends done
  #                      and `{:fail, turn_id}` sends `{:error, :failed}`
  #   "block_init"       `init/3` blocks
  #   "fail_init"        `init/3` returns an error
  #   "block_turn"       the turn callback blocks
  #   "error_turn"       a turn answers `{:error, :refused}`
  #   "crash_turn"       the turn callback raises
  #   "late_turn"        a turn answers after 300 ms, then as "echo"
  #   "block_interrupt"  "hang", and the interrupt callback blocks
  #   "error_interrupt"  "hang", and an interrupt answers an error
  #   "late_interrupt"   "hang", and an interrupt answers after 100 ms
  #   "block_close"      "echo", and the close callback blocks
  #   "late_close"       "echo", and a close answers :ok after 100 ms
  #   "busy"             "echo", and an idle close answers :busy
  #   "busy_turn"        "busy", and the idle close starts the program turn
  #                      "p1" with the tool request "c1" and a context
  #                      request before its answer
  #   "late_idle"        "echo", and an idle close answers :ok after 100 ms
  #   "block_idle"       "echo", and the idle close callback blocks
  #   "bad_action"       a turn gives an action that is not one
  #   "bad_reply"        a turn answers `:maybe`
  #   "bad_event"        a turn answers :ok and sends a malformed event
  #   "flood"            "hang"; the message `{:flood, turn_id}` sends
  #                      10,002 deltas and done
  #   "stop"             "hang"; the message `:stop` stops the provider,
  #                      `:bad_return` returns a bad value from `info/2`,
  #                      and `:exit_normal` calls `exit(:normal)` in it
  #   "exit_init"        `init/3` calls `exit(:normal)`
  #   "exit_turn"        the turn callback calls `exit(:normal)`
  #   "context"          a turn answers :ok; the message `{:need_context,
  #                      turn_id, text}` sends `text`, a `message_end`, and
  #                      `{:need_context, turn_id}`; a context answers :ok,
  #                      then done, or the error of the context
  #   "context_hold"     "context", and a context gets no answer
  #   "tools"            "hang"; the message `{:tool_request, turn_id, id,
  #                      name, args}` asks for a Helyx tool, and `{:cancel, id}`
  #                      withdraws it; `{:ping, pid}`
  #                      sends `:pong` to pid
  #   "tools_late"       "tools", and a tool result answers after 100 ms
  #   "label"            "echo"; a provider process started with no
  #                      `:resume_id` reports a new label on its
  #                      first turn
  #   "events.<name>"    a turn answers :ok, sends the events of <name>, then
  #                      a text delta "ok" and done:
  #     "id1"     a resume id of 1 byte
  #     "id256"   a resume id of 256 bytes, multibyte
  #     "id257"   an id of 257 bytes
  #     "id0"     an empty id
  #     "raw_id"  an id that is not valid UTF-8
  #     "orphan"  a tool result for a call of no completed message
  #     "raw_result_id"  a tool result whose id is not valid UTF-8
  #     "exit_big"  the turn callback exits with a reason of 101 digits
  #     "big_cut" a cut of 101 digits, over the digit limit
  #     "max_cut" a cut of 100 digits, at the digit limit
  #     "neg_cut" a cut of -1
  #     "result_N" a tool call and its result of N bytes
  #     "result_multibyte" a result of 65,537 bytes: a 2-byte character
  #                across the limit of 65,536
  #     "result_raw" a result of 65,536 bytes that are not valid UTF-8
  #     "dup_id"  two tool calls with one id, then two results
  #     "open_call"  "dup_id" with no second result and no text after it
  #     "late_result"  a call, a text message, then the call's result
  #     "rejected"  a rejected tool call, valid only in a Loop stream
  #
  # A steer answers :ok with no `user_message` unless the model says
  # otherwise; the "steer_" models are "hang" for a turn:
  #   "steer_take"       a steer answers :ok and the provider takes it
  #   "steer_reject"     a steer answers :rejected
  #   "steer_error"      a steer answers `{:error, :lost}`
  #   "steer_hold"       a steer gets no answer; the controller gets
  #                      `{:held, from}`, and the message `{:answer, from,
  #                      value}` answers it
  #   "steer_block"      the steer callback blocks
  #   "steer_early"      "steer_hold", and the provider takes the steer
  #                      before its answer
  @behaviour Helyx.Provider

  alias Helyx.Message.ToolCall

  @hang ~w(hang flood stop tools tools_late block_interrupt error_interrupt late_interrupt) ++
          ~w(steer_take steer_reject steer_error steer_hold steer_block steer_early)

  @done {:done, %{stop_reason: :end_turn, usage: %{}}}

  # The events of each "events.<name>" model with a fixed list.
  @events %{
    "id1" => [{:resume, "a", 0}],
    "id256" => [{:resume, String.duplicate("é", 128), 0}],
    "id257" => [{:resume, "a" <> String.duplicate("é", 128), 0}],
    "id0" => [{:resume, "", 0}],
    "raw_id" => [{:resume, <<255>>, 0}],
    "big_cut" => [{:resume, "a", Integer.pow(10, 100)}],
    "max_cut" => [{:resume, "a", Integer.pow(10, 100) - 1}],
    "neg_cut" => [{:resume, "a", -1}],
    "orphan" => [{:tool_result, "nope", {:ok, "lost"}}],
    "raw_result_id" => [{:tool_result, <<255>>, {:ok, "lost"}}],
    "rejected" => [
      {:rejected_tool_call, %ToolCall{id: "r", name: "read", arguments: %{}}, "bad"}
    ],
    "late_result" => [
      {:tool_call, %ToolCall{id: "t", name: "read", arguments: %{}}},
      {:message_end, :tool_use, %{}},
      {:text_delta, "x"},
      {:message_end, :end_turn, %{}},
      {:tool_result, "t", {:ok, "late"}}
    ],
    "dup_id" => [
      {:tool_call, %ToolCall{id: "t", name: "read", arguments: %{}}},
      {:tool_call, %ToolCall{id: "t", name: "bash", arguments: %{}}},
      {:message_end, :tool_use, %{}},
      {:tool_result, "t", {:ok, "one"}},
      {:tool_result, "t", {:ok, "two"}}
    ]
  }

  def controller(core), do: :"#{core}_controller"

  @impl true
  def id, do: "conn"

  @impl true
  def release(handles, mode, _deadline) do
    for {:report, pid} <- handles, do: send(pid, {:release, mode, handles})
    []
  end

  @impl true
  def init(model, tools, opts) do
    ctl = Process.whereis(controller(opts[:core]))

    if ctl do
      send(ctl, {:conn, :init, self(), {model, tools, opts}})
      Helyx.Tool.hold({:report, ctl})
      send(ctl, {:linked, self(), spawn_link(fn -> Process.sleep(:infinity) end)})
    end

    case model do
      "block_init" -> Process.sleep(:infinity)
      "exit_init" -> exit(:normal)
      "fail_init" -> {:error, :no_program}
      _ -> {:ok, %{model: model, ctl: ctl, label: opts[:resume_id]}}
    end
  end

  @impl true
  def request({:turn, id, _} = request, from, %{model: "label", label: nil} = state) do
    label = "h#{System.unique_integer([:positive])}"
    {:ok, [reply | events], state} = request(request, from, %{state | label: label})
    {:ok, [reply, {:event, id, {:resume, label, 0}} | events], state}
  end

  def request(request, from, %{model: model, ctl: ctl} = state) do
    if ctl, do: send(ctl, {:conn, kind(request), self(), request})

    if ctl && model in ["steer_hold", "steer_early"] && kind(request) == :steer,
      do: send(ctl, {:held, from})

    {:ok, answer(model, request, from), state}
  end

  @impl true
  def info({:late, from, request}, state),
    do: {:ok, answer("echo", request, from), state}

  def info({:finish, turn_id}, state), do: {:ok, [{:event, turn_id, @done}], state}

  def info({:fail, turn_id}, state),
    do: {:ok, [{:event, turn_id, {:error, :failed}}], state}

  def info({:flood, turn_id}, state) do
    deltas = for _ <- 1..10_002, do: {:event, turn_id, {:text_delta, "x"}}
    {:ok, deltas ++ [{:event, turn_id, @done}], state}
  end

  def info(:stop, state), do: {:stop, :gone, state}
  def info(:bad_return, _state), do: :nope
  def info(:exit_normal, _state), do: exit(:normal)

  def info({:need_context, turn_id, text}, state) do
    message_end = {:message_end, :end_turn, %{}}

    {:ok,
     [
       {:event, turn_id, {:text_delta, text}},
       {:event, turn_id, message_end},
       {:need_context, turn_id}
     ], state}
  end

  def info({:tool_request, turn_id, id, name, args}, state),
    do: {:ok, [{:event, turn_id, {:tool_request, id, name, args}}], state}

  def info({:cancel, id}, state),
    do: {:ok, [{:cancel_tool, id}], state}

  def info({:ping, pid}, state) do
    send(pid, :pong)
    {:ok, [], state}
  end

  def info({:answer, from, value}, state), do: {:ok, [{:reply, from, value}], state}

  # Several actions from one callback, as one input batch of a program.
  def info({:batch, actions}, state), do: {:ok, actions, state}

  defp kind({kind, _, _, _}), do: kind
  defp kind({kind, _, _}), do: kind
  defp kind({kind, _}), do: kind
  defp kind(:close), do: :close
  defp kind(:idle_close), do: :idle_close

  # The blocks and the raise are the point of this provider.
  @dialyzer {:nowarn_function, answer: 3}
  defp answer("block_turn", {:turn, _, _}, _from), do: Process.sleep(:infinity)
  defp answer("error_turn", {:turn, _, _}, from), do: [{:reply, from, {:error, :refused}}]
  defp answer("crash_turn", {:turn, _, _}, _from), do: raise("turn crashed")
  defp answer("exit_turn", {:turn, _, _}, _from), do: exit(:normal)
  defp answer("context", {:turn, _, _}, from), do: [{:reply, from, :ok}]

  defp answer("context", {:context, id, {:ok, _context}}, from),
    do: [{:reply, from, :ok}, {:event, id, @done}]

  defp answer("context", {:context, id, {:error, reason}}, from),
    do: [{:reply, from, :ok}, {:event, id, {:error, reason}}]

  defp answer("context_hold", {:context, _, _}, _from), do: []
  defp answer("context_hold", request, from), do: answer("context", request, from)

  defp answer("events." <> name, {:turn, id, _}, from),
    do: [{:reply, from, :ok} | Enum.map(turn_events(name), &{:event, id, &1})]

  defp answer("bad_action", {:turn, _, _}, _from), do: [:bogus]
  defp answer("bad_reply", {:turn, _, _}, from), do: [{:reply, from, :maybe}]

  defp answer("bad_event", {:turn, id, _}, from),
    do: [{:reply, from, :ok}, {:event, id, {:text_delta, 42}}]

  defp answer("late_turn", {:turn, _, _} = request, from), do: later(from, request, 300)
  defp answer("late_interrupt", {:interrupt, _} = request, from), do: later(from, request, 100)
  defp answer("block_interrupt", {:interrupt, _}, _from), do: Process.sleep(:infinity)

  defp answer("error_interrupt", {:interrupt, _}, from),
    do: [{:reply, from, {:error, :still_queued}}]

  defp answer("block_close", :close, _from), do: Process.sleep(:infinity)
  defp answer("late_close", :close = request, from), do: later(from, request, 100)
  defp answer("busy", :idle_close, from), do: [{:reply, from, :busy}]

  defp answer("busy_turn", :idle_close, from) do
    call = {:tool_request, "c1", "upcase", %{"text" => "hi"}}

    [
      {:event, "p1", :turn_start},
      {:event, "p1", call},
      {:need_context, "p1"},
      {:reply, from, :busy}
    ]
  end

  defp answer("late_idle", :idle_close = request, from), do: later(from, request, 100)
  defp answer("block_idle", :idle_close, _from), do: Process.sleep(:infinity)

  defp answer("steer_take", {:steer, id, steer_id, _text}, from),
    do: [{:reply, from, :ok}, {:event, id, {:user_message, steer_id}}]

  defp answer("steer_reject", {:steer, _, _, _}, from), do: [{:reply, from, :rejected}]
  defp answer("steer_error", {:steer, _, _, _}, from), do: [{:reply, from, {:error, :lost}}]
  defp answer("steer_block", {:steer, _, _, _}, _from), do: Process.sleep(:infinity)

  defp answer("steer_hold", {:steer, _, _, _}, _from), do: []

  defp answer("tools_late", {:tool_result, _, _, _} = request, from),
    do: later(from, request, 100)

  defp answer("steer_early", {:steer, id, steer_id, _text}, _from),
    do: [{:event, id, {:user_message, steer_id}}]

  defp answer(model, {:turn, id, _}, from) when model in @hang,
    do: [{:reply, from, :ok}, {:event, id, {:text_delta, "so far"}}]

  defp answer(_model, {:turn, id, context}, from) do
    text = "echo:#{context.system}|#{Helyx.Message.text(List.last(context.messages))}"
    [{:reply, from, :ok}, {:event, id, {:text_delta, text}}, {:event, id, @done}]
  end

  defp answer(_model, _request, from), do: [{:reply, from, :ok}]

  defp later(from, request, ms) do
    Process.send_after(self(), {:late, from, request}, ms)
    []
  end

  defp turn_events("exit_big"), do: exit({:boom, Integer.pow(10, 100)})

  defp turn_events("open_call"),
    do: @events |> Map.fetch!("dup_id") |> Enum.drop(-1) |> Enum.concat([@done])

  defp turn_events("result_" <> kind) do
    call = %ToolCall{id: "c1", name: "bash", arguments: %{}}

    [
      {:tool_call, call},
      {:message_end, :tool_use, %{}},
      {:tool_result, "c1", {:ok, result_text(kind)}},
      {:text_delta, "ok"},
      @done
    ]
  end

  defp turn_events(name), do: Map.fetch!(@events, name) ++ [{:text_delta, "ok"}, @done]

  defp result_text("multibyte"), do: String.duplicate("x", 65_535) <> "é"
  defp result_text("raw"), do: :binary.copy(<<255>>, 65_536)
  defp result_text(bytes), do: String.duplicate("x", String.to_integer(bytes))
end

defmodule Helyx.Test.PrepareContext do
  @moduledoc false
  # Sets the system prompt to "prepared", unless the last user message is
  # "block_prepare" (the build blocks), "raise_prepare" (it raises),
  # "nil_build" (it returns nil), "bad_build" (it returns a map),
  # "forged_build" (a struct without :system), "bad_system" (a system
  # prompt that is not a string), or "bad_messages_build" (the messages
  # are not a list). A last message "fresh" sets it to "prepared for
  # <turn_id>".
  @behaviour Helyx.ModelContext

  @impl true
  def build(context, opts) do
    case context.messages |> List.last() |> Helyx.Message.text() do
      "fresh" -> %{context | system: "prepared for #{opts[:turn_id]}"}
      text -> build_text(text, context)
    end
  end

  defp build_text(text, context) do
    case text do
      "block_prepare" -> Process.sleep(:infinity)
      "raise_prepare" -> raise "prepare failed"
      "nil_build" -> nil
      "bad_build" -> Map.from_struct(context)
      "forged_build" -> Map.delete(context, :system)
      "bad_system" -> %{context | system: :prepared}
      "bad_messages_build" -> %{context | messages: nil}
      _ -> %{context | system: "prepared"}
    end
  end
end

defmodule Helyx.Test.PrepareCompaction do
  @moduledoc false
  # Keeps the context, unless the last user message is "nil_compact" (it
  # returns nil), "bad_compact" (it returns a map), "forged_compact" (a
  # struct without :system), "bad_system_compact" (a system prompt that is
  # not a string), or "bad_messages" (the messages are not a list).
  @behaviour Helyx.Compaction

  @impl true
  def compact(context, _opts) do
    case context.messages |> List.last() |> Helyx.Message.text() do
      "nil_compact" -> nil
      "bad_compact" -> Map.from_struct(context)
      "forged_compact" -> Map.delete(context, :system)
      "bad_system_compact" -> %{context | system: :compacted}
      "bad_messages" -> %{context | messages: nil}
      _ -> context
    end
  end
end
