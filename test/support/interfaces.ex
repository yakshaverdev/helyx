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

defmodule Helyx.Test.ModelContextTwin do
  @moduledoc false
  @behaviour Helyx.ModelContext

  @impl true
  def build(context, _opts), do: context
end

defmodule Helyx.Test.Compaction do
  @moduledoc false
  # Appends to the system prompt so tests see it ran after model context.
  @behaviour Helyx.Compaction

  @impl true
  def compact(context, _opts), do: %{context | system: "#{context.system}, compacted"}
end

defmodule Helyx.Test.CompactionTwin do
  @moduledoc false
  @behaviour Helyx.Compaction

  @impl true
  def compact(context, _opts), do: context
end

defmodule Helyx.Test.NoInterface do
  @moduledoc false
  def name, do: "none"
end

defmodule Helyx.Test.ProviderTwin do
  @moduledoc false
  # A second provider with the same id as Helyx.Test.Provider.
  @behaviour Helyx.Provider

  @impl true
  def id, do: "test"

  @impl true
  def stream(_model, _context, _opts), do: {:ok, []}
end

defmodule Helyx.Test.ProviderOther do
  @moduledoc false
  # A second provider with its own id, so a test can switch between two
  # provider modules. Every model answers "from other".
  @behaviour Helyx.Provider

  @impl true
  def id, do: "other"

  @impl true
  def stream(_model, _context, _opts) do
    {:ok, [{:text_delta, "from other"}, {:done, %{stop_reason: :end_turn, usage: %{}}}]}
  end
end

defmodule Helyx.Test.BadTurn do
  @moduledoc false
  # A provider whose `turn/0` is not `:local` or `:external`.
  @behaviour Helyx.Provider

  @impl true
  def id, do: "bad_turn"

  # The bad return is the point of this provider.
  @dialyzer {:nowarn_function, turn: 0}
  @impl true
  def turn, do: :bogus

  @impl true
  def stream(_model, _context, _opts), do: {:ok, []}
end

defmodule Helyx.Test.BadId do
  @moduledoc false
  # A provider whose `id/0` is "bad_id" until the calling process puts a
  # mode under `:bad_id`. Then it raises, throws, exits, or returns the value.
  @behaviour Helyx.Provider

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

defmodule Helyx.Test.RaisingTurn do
  @moduledoc false
  @behaviour Helyx.Provider

  @impl true
  def id, do: "raising_turn"

  @impl true
  def turn, do: raise("no turn")

  @impl true
  def stream(_model, _context, _opts), do: {:ok, []}
end

defmodule Helyx.Test.Harness do
  @moduledoc false
  # A provider with an external turn whose model name selects its harness
  # events. Each stream ends with a text delta and done.
  #
  #   "id1"     a harness session id of 1 byte
  #   "id256"   a harness session id of 256 bytes, multibyte
  #   "id257"   an id of 257 bytes
  #   "id0"     an empty id
  #   "raw_id"  an id that is not valid UTF-8
  #   "orphan"  a tool result for a call of no completed message
  #   "raw_result_id"  a tool result whose id is not valid UTF-8
  #   "exit_big"  the stream exits with a reason of 101 digits
  #   "big_cut" a cut of 101 digits, over the digit limit
  #   "max_cut" a cut of 100 digits, at the digit limit
  #   "neg_cut" a cut of -1
  #   "result_N" a tool call and its result of N bytes
  #   "result_multibyte" a result of 65,537 bytes: a 2-byte character
  #              across the limit of 65,536
  #   "result_raw" a result of 65,536 bytes that are not valid UTF-8
  #   "dup_id"  two tool calls with one id, then two results
  #   "open_call"  "dup_id" with no second result and no text after it
  #   "late_result"  a call, a text message, then the call's result
  #   "rejected"  a rejected tool call, valid only on a local turn
  @behaviour Helyx.Provider

  @impl true
  def id, do: "harness"

  @impl true
  def turn, do: :external

  @impl true
  def stream("exit_big", _context, _opts), do: exit({:boom, Integer.pow(10, 100)})

  def stream("open_call", _context, _opts),
    do:
      {:ok,
       events("dup_id")
       |> Enum.drop(-1)
       |> Enum.concat([{:done, %{stop_reason: :end_turn, usage: %{}}}])}

  def stream(model, _context, _opts),
    do:
      {:ok,
       events(model) ++ [{:text_delta, "ok"}, {:done, %{stop_reason: :end_turn, usage: %{}}}]}

  defp events("id1"), do: [{:harness_session, "a", 0}]
  defp events("big_cut"), do: [{:harness_session, "a", Integer.pow(10, 100)}]
  defp events("max_cut"), do: [{:harness_session, "a", Integer.pow(10, 100) - 1}]
  defp events("neg_cut"), do: [{:harness_session, "a", -1}]

  defp events("late_result") do
    call = %Helyx.Message.ToolCall{id: "t", name: "read", arguments: %{}}

    [
      {:tool_call, call},
      {:message_end, :tool_use, %{}},
      {:text_delta, "x"},
      {:message_end, :end_turn, %{}},
      {:tool_result, "t", {:ok, "late"}}
    ]
  end

  defp events("dup_id") do
    read = %Helyx.Message.ToolCall{id: "t", name: "read", arguments: %{}}
    bash = %Helyx.Message.ToolCall{id: "t", name: "bash", arguments: %{}}

    [
      {:tool_call, read},
      {:tool_call, bash},
      {:message_end, :tool_use, %{}},
      {:tool_result, "t", {:ok, "one"}},
      {:tool_result, "t", {:ok, "two"}}
    ]
  end

  defp events("result_" <> kind) do
    call = %Helyx.Message.ToolCall{id: "c1", name: "bash", arguments: %{}}

    [
      {:tool_call, call},
      {:message_end, :tool_use, %{}},
      {:tool_result, "c1", {:ok, result_text(kind)}}
    ]
  end

  defp events("rejected") do
    call = %Helyx.Message.ToolCall{id: "r", name: "read", arguments: %{}}
    [{:rejected_tool_call, call, "bad"}]
  end

  defp events("id256"), do: [{:harness_session, String.duplicate("é", 128), 0}]
  defp events("id257"), do: [{:harness_session, "a" <> String.duplicate("é", 128), 0}]
  defp events("id0"), do: [{:harness_session, "", 0}]
  defp events("raw_id"), do: [{:harness_session, <<255>>, 0}]
  defp events("orphan"), do: [{:tool_result, "nope", {:ok, "lost"}}]
  defp events("raw_result_id"), do: [{:tool_result, <<255>>, {:ok, "lost"}}]

  defp result_text("multibyte"), do: String.duplicate("x", 65_535) <> "é"
  defp result_text("raw"), do: :binary.copy(<<255>>, 65_536)
  defp result_text(bytes), do: String.duplicate("x", String.to_integer(bytes))
end

defmodule Helyx.Test.Provider do
  @moduledoc false
  # A provider whose model name selects a stream shape, so session tests can
  # exercise streams that end badly.
  #
  #   "ok"         one delta, then done, after a short pause
  #   "empty"      an empty stream, no terminal event
  #   "crash"      one delta, then the stream raises
  #   "overrun"    a delta, done, then a raise if pulled further
  #   "blocks"     thinking, text, and a tool call, then done; text after the result
  #   "error_tail" an error event, then a raise if pulled further
  #   "garbage"    one event that is not a stream event
  #   "raw_bytes"  a text delta that is not valid UTF-8
  #   "raw_call"   a tool call whose name is not valid UTF-8
  #   "bad_stop"   done with a stop reason outside the file format's set
  #   "harness_event" a message end, which only a harness may send
  #   "bad_args"   a tool call whose arguments the file format cannot hold
  #   "recover"    a first turn the file cannot hold, then a clean "again" turn
  #   "wide"       a delta tuple with an extra element
  #   "tools"      the names of the tools in the context, as text
  #   "system"     the system prompt in the context, as text
  #   "loop"       calls upcase and then a missing tool; after the results,
  #                echoes them as text
  #   "serial"     three calls to the slow tool, then echoes the results
  #   "bad_call"   a tool call whose name is not a string
  #   "kill"       calls the kill tool, then echoes the result as text
  #   "binary"     calls the binary tool, then echoes the result as text
  #   "hang"       one delta, then the stream blocks forever
  #   "transcript" every message in the context as "role:text" lines
  #   "abort"      three calls to the slow tool that sleep for a minute;
  #                after the results, echoes them as text
  #   "stuck"      one call to the hold tool: a handle whose release takes
  #                800 ms and one that stays held, a sleep of a minute;
  #                after the result, echoes the results
  #   "steer"      one slow call; after the result, echoes the user message
  #                texts so far, so tests see which steers reached the call
  @behaviour Helyx.Provider

  @impl true
  def id, do: "test"

  @impl true
  def stream("ok", _context, _opts) do
    {:ok, Stream.map([{:text_delta, "ok"}, done()], &tap(&1, fn _ -> Process.sleep(50) end))}
  end

  def stream("empty", _context, _opts), do: {:ok, []}

  def stream("loop", %Helyx.Context{messages: messages}, _opts) do
    case List.last(messages) do
      %Helyx.Message{role: :tool_result} ->
        {:ok, echo_results(messages)}

      _ ->
        {:ok,
         [
           {:tool_call,
            %Helyx.Message.ToolCall{id: "c1", name: "upcase", arguments: %{"text" => "hi"}}},
           {:tool_call, %Helyx.Message.ToolCall{id: "c2", name: "nope", arguments: %{}}},
           {:done, %{stop_reason: :tool_use, usage: %{}}}
         ]}
    end
  end

  def stream("tools", %Helyx.Context{tools: tools}, _opts) do
    {:ok, [{:text_delta, Enum.map_join(tools, ",", & &1.name)}, done()]}
  end

  def stream("system", %Helyx.Context{system: system}, _opts) do
    {:ok, [{:text_delta, system || "no system"}, done()]}
  end

  def stream("crash", _context, _opts) do
    {:ok, raise_after([{:text_delta, "so far"}], "boom")}
  end

  def stream("blocks", %Helyx.Context{messages: messages}, _opts) do
    case List.last(messages) do
      %Helyx.Message{role: :tool_result} -> {:ok, [{:text_delta, "done"}, done()]}
      _ -> {:ok, blocks()}
    end
  end

  def stream("serial", %Helyx.Context{messages: messages}, _opts) do
    case List.last(messages) do
      %Helyx.Message{role: :tool_result} ->
        {:ok, echo_results(messages)}

      _ ->
        {:ok, slow_calls([{"1", 60}, {"2", 30}, {"3", 0}]) ++ [done()]}
    end
  end

  # Six calls: an integer of 400,000 digits nested in the arguments, a good
  # call whose struct has one more key with the large integer, the largest
  # permitted integer (100 digits), a good call with the id of the first
  # call, the large integer as a map key, and the large integer in a struct
  # that JSON encodes. The `:done` map of the last provider call holds the
  # large integer in its usage and in one more key.
  def stream("big_int", %Helyx.Context{messages: messages}, _opts) do
    huge = huge()

    case List.last(messages) do
      %Helyx.Message{role: :tool_result} ->
        [text, {:done, done}] = echo_results(messages)
        done = Map.put(%{done | usage: %{input: huge, output: 3}}, :extra, huge)
        {:ok, [text, {:done, done}]}

      _ ->
        call = fn id, args ->
          {:tool_call, %Helyx.Message.ToolCall{id: id, name: "upcase", arguments: args}}
        end

        {:ok,
         [
           call.("c1", %{"text" => "one", "n" => [%{"deep" => -huge}]}),
           {:tool_call, Map.put(elem(call.("c2", %{"text" => "two"}), 1), :extra, huge)},
           call.("c3", %{"text" => "three", "n" => 10 ** 100 - 1}),
           call.("c1", %{"text" => "four"}),
           call.("c5", %{"text" => "five", huge => 1}),
           call.("c6", %{"text" => "six", "d" => %Date{year: huge, month: 1, day: 1}}),
           {:done, %{stop_reason: :tool_use, usage: %{}}}
         ]}
    end
  end

  def stream("bad_call", _context, _opts) do
    {:ok, [{:tool_call, %Helyx.Message.ToolCall{id: "c", name: %{}, arguments: %{}}}]}
  end

  def stream("kill", %Helyx.Context{messages: messages}, _opts) do
    case List.last(messages) do
      %Helyx.Message{role: :tool_result} = m ->
        {:ok, [{:text_delta, Helyx.Message.text(m)}, done()]}

      _ ->
        {:ok,
         [{:tool_call, %Helyx.Message.ToolCall{id: "k", name: "kill", arguments: %{}}}, done()]}
    end
  end

  def stream("binary", %Helyx.Context{messages: messages}, _opts) do
    case List.last(messages) do
      %Helyx.Message{role: :tool_result} ->
        {:ok, echo_results(messages)}

      _ ->
        {:ok,
         [{:tool_call, %Helyx.Message.ToolCall{id: "b", name: "binary", arguments: %{}}}, done()]}
    end
  end

  def stream("hang", _context, _opts) do
    {:ok,
     Stream.concat(
       [{:text_delta, "so far"}],
       Stream.repeatedly(fn -> Process.sleep(:infinity) end)
     )}
  end

  def stream("abort", %Helyx.Context{messages: messages}, _opts) do
    if Enum.any?(messages, &(&1.role == :tool_result)) do
      {:ok, echo_results(messages)}
    else
      {:ok, slow_calls(for id <- ["1", "2", "3"], do: {id, 60_000}) ++ [done()]}
    end
  end

  def stream("stuck", %Helyx.Context{messages: messages}, _opts) do
    if Enum.any?(messages, &(&1.role == :tool_result)) do
      {:ok, echo_results(messages)}
    else
      arguments = %{"handles" => [%{"slow" => 800}, "keep"], "ms" => 60_000}
      call = %Helyx.Message.ToolCall{id: "1", name: "hold", arguments: arguments}
      {:ok, [{:tool_call, call}, {:done, %{stop_reason: :tool_use, usage: %{}}}]}
    end
  end

  def stream("error_tail", _context, _opts) do
    {:ok, raise_after([{:error, :overloaded}], "pulled past the error")}
  end

  def stream("transcript", %Helyx.Context{messages: messages}, _opts) do
    text = Enum.map_join(messages, "\n", &"#{&1.role}:#{Helyx.Message.text(&1)}")
    {:ok, [{:text_delta, text}, done()]}
  end

  def stream("steer", %Helyx.Context{messages: messages}, _opts) do
    if Enum.any?(messages, &(&1.role == :tool_result)) do
      users = for %{role: :user} = m <- messages, do: Helyx.Message.text(m)
      {:ok, [{:text_delta, Enum.join(users, "|")}, done()]}
    else
      {:ok, slow_calls([{"1", 200}]) ++ [done()]}
    end
  end

  def stream("garbage", _context, _opts), do: {:ok, [{:text_delta, 42}]}
  def stream("raw_bytes", _context, _opts), do: {:ok, [{:text_delta, <<"hi", 255>>}]}

  def stream("raw_call", _context, _opts) do
    call = %Helyx.Message.ToolCall{id: "c", name: <<"bash", 255>>, arguments: %{}}
    {:ok, [{:tool_call, call}, done()]}
  end

  def stream("bad_stop", _context, _opts),
    do: {:ok, [{:text_delta, "hi"}, {:done, %{stop_reason: :refusal, usage: %{}}}]}

  def stream("harness_event", _context, _opts),
    do: {:ok, [{:text_delta, "hi"}, {:message_end, :end_turn, %{}}, done()]}

  # Text, one good call, and one call the provider rejects; the next
  # provider call echoes both results.
  def stream("rejected", %Helyx.Context{messages: messages}, _opts) do
    case List.last(messages) do
      %Helyx.Message{role: :tool_result} ->
        {:ok, echo_results(messages)}

      _ ->
        good = %Helyx.Message.ToolCall{id: "c1", name: "upcase", arguments: %{"text" => "one"}}
        bad = %Helyx.Message.ToolCall{id: "c2", name: "upcase", arguments: %{}}

        {:ok,
         [
           {:text_delta, "Trying"},
           {:tool_call, good},
           {:rejected_tool_call, bad, "the arguments are not a valid JSON object"},
           {:done, %{stop_reason: :tool_use, usage: %{}}}
         ]}
    end
  end

  # A rejected call with a reason of N bytes, not valid UTF-8, or not text.
  def stream("reject_bytes_" <> bytes, _context, _opts),
    do: reject_with(String.duplicate("x", String.to_integer(bytes)))

  # 512 2-byte characters, 1,024 bytes; then one more byte.
  def stream("reject_multibyte_1024", _context, _opts),
    do: reject_with(String.duplicate("é", 512))

  def stream("reject_multibyte_1025", _context, _opts),
    do: reject_with(String.duplicate("é", 512) <> "x")

  def stream("reject_raw", _context, _opts), do: reject_with(<<"bad", 255>>)
  def stream("reject_atom", _context, _opts), do: reject_with(:bad)

  def stream("bad_args", _context, _opts) do
    call = %Helyx.Message.ToolCall{id: "c", name: "bash", arguments: %{"text" => {1, 2}}}
    {:ok, [{:tool_call, call}, done()]}
  end

  # First turn ends with a usage the file format cannot hold; a later "again"
  # prompt ends cleanly, so a test can prove persistence survived the first.
  def stream("recover", %Helyx.Context{messages: messages}, _opts) do
    case List.last(messages) do
      %Helyx.Message{role: :user, content: [%Helyx.Message.Text{text: "again"}]} ->
        {:ok, [{:text_delta, "recovered"}, done()]}

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
    done = %Helyx.Message.ToolCall{id: huge(), name: "x", arguments: %{}}
    {:ok, [{:text_delta, "hi"}, {:done, Map.merge(done, %{stop_reason: :end_turn, usage: %{}})}]}
  end

  # A struct in place of the arguments map.
  def stream("struct_args", _context, _opts) do
    arguments = %Date{year: huge(), month: 1, day: 1}
    {:ok, [{:tool_call, %Helyx.Message.ToolCall{id: "c1", name: "upcase", arguments: arguments}}]}
  end

  def stream("wide", _context, _opts), do: {:ok, [{:text_delta, "hello", :extra}]}

  def stream("overrun", _context, _opts) do
    {:ok, raise_after([{:text_delta, "kept"}, done()], "pulled past done")}
  end

  defp reject_with(reason) do
    call = %Helyx.Message.ToolCall{id: "r", name: "upcase", arguments: %{}}
    {:ok, [{:rejected_tool_call, call, reason}, done()]}
  end

  # A lazy tail that raises when pulled, so a consumer that reads past
  # `events` fails its test instead of passing silently.
  defp raise_after(events, message) do
    Stream.concat(events, Stream.map([1], fn _ -> raise message end))
  end

  defp blocks do
    call = %Helyx.Message.ToolCall{id: "call_1", name: "bash", arguments: %{"command" => "ls"}}

    [
      {:thinking_delta, "hm"},
      {:thinking_delta, "m"},
      {:text_delta, "Listing"},
      {:text_delta, "."},
      {:tool_call, call},
      done()
    ]
  end

  defp slow_calls(pairs) do
    for {id, ms} <- pairs do
      {:tool_call,
       %Helyx.Message.ToolCall{id: id, name: "slow", arguments: %{"ms" => ms, "text" => id}}}
    end
  end

  # The tool result texts so far, joined with "|", then done.
  defp echo_results(messages) do
    results = for %{role: :tool_result} = m <- messages, do: Helyx.Message.text(m)
    [{:text_delta, Enum.join(results, "|")}, done()]
  end

  defp huge, do: String.to_integer(String.duplicate("7", 400_000))

  defp done, do: {:done, %{stop_reason: :end_turn, usage: %{}}}
end

defmodule Helyx.Test.Tool.Upcase do
  @moduledoc false
  @behaviour Helyx.Tool

  @impl true
  def name, do: "upcase"
  @impl true
  def description, do: "Upcases text."
  @impl true
  def parameters, do: %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}}
  @impl true
  def run(%{"text" => text}, _cwd), do: {:ok, String.upcase(text)}
end

defmodule Helyx.Test.Tool.UpcaseTwin do
  @moduledoc false
  # A second tool with the same name as Helyx.Test.Tool.Upcase.
  @behaviour Helyx.Tool

  @impl true
  def name, do: "upcase"
  @impl true
  def description, do: "Upcases text."
  @impl true
  def parameters, do: %{"type" => "object"}
  @impl true
  def run(_args, _cwd), do: {:ok, "twin"}
end

defmodule Helyx.Test.Tool.Kill do
  @moduledoc false
  # A tool whose Task dies without returning.
  @behaviour Helyx.Tool

  @impl true
  def name, do: "kill"
  @impl true
  def description, do: "Kills its own Task."
  @impl true
  def parameters, do: %{"type" => "object"}
  # run/2 never returns; the brutal kill is the point.
  @dialyzer {:nowarn_function, run: 2}
  @impl true
  def run(_args, _cwd), do: Process.exit(self(), :kill)
end

defmodule Helyx.Test.Tool.Binary do
  @moduledoc false
  # Returns bytes that are not valid UTF-8, so tests can see the hands make
  # the result valid.
  @behaviour Helyx.Tool

  @impl true
  def name, do: "binary"
  @impl true
  def description, do: "Returns invalid bytes."
  @impl true
  def parameters, do: %{"type" => "object"}
  @impl true
  def run(_args, _cwd), do: {:ok, <<"a", 255, "b">>}
end

defmodule Helyx.Test.Tool.Slow do
  @moduledoc false
  # Sleeps `ms` and returns `text`, so call order and finish order can differ.
  @behaviour Helyx.Tool

  @impl true
  def name, do: "slow"
  @impl true
  def description, do: "Sleeps, then echoes."
  @impl true
  def parameters, do: %{"type" => "object"}
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
  #   :keep           stays held
  #   {:keep, agent}  stays held while the Agent holds true
  #   :raise, :exit   the release raises or exits
  #   :bad            the release returns a handle it was not given
  #   :improper       the release returns an improper list
  #
  # "keep" and %{"slow" => ms} are the forms a transcript can hold. Every
  # other handle is released.
  @behaviour Helyx.Tool

  @impl true
  def name, do: "hold"
  @impl true
  def description, do: "Holds handles."
  @impl true
  def parameters, do: %{"type" => "object"}
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
    Process.sleep(Enum.sum(for %{"slow" => ms} <- handles, do: ms))

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
  @behaviour Helyx.Tool

  @impl true
  def name, do: "hold_two"
  @impl true
  defdelegate description, to: Helyx.Test.Tool.Hold
  @impl true
  defdelegate parameters, to: Helyx.Test.Tool.Hold
  @impl true
  defdelegate run(args, cwd), to: Helyx.Test.Tool.Hold
  @impl true
  defdelegate release(handles, mode, deadline), to: Helyx.Test.Tool.Hold
end

defmodule Helyx.Test.Tool.HoldBare do
  @moduledoc false
  # Holds a handle but has no release/3.
  @behaviour Helyx.Tool

  @impl true
  def name, do: "hold_bare"
  @impl true
  def description, do: "Holds a handle it cannot release."
  @impl true
  def parameters, do: %{"type" => "object"}
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
  @behaviour Helyx.Tool

  @impl true
  def name, do: "unavailable"
  @impl true
  def description, do: "Never available."
  @impl true
  def parameters, do: %{"type" => "object"}
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
  # handles}` to the controller.
  #
  #   "echo"             a turn answers :ok, then "echo:<system>|<last user
  #                      text>" and done; an interrupt and a close answer :ok
  #   "hang"             a turn answers :ok and sends "so far"; the message
  #                      `{:finish, turn_id}` sends done
  #   "block_init"       `harness_init/3` blocks
  #   "fail_init"        `harness_init/3` returns an error
  #   "block_turn"       the turn callback blocks
  #   "error_turn"       a turn answers `{:error, :refused}`
  #   "crash_turn"       the turn callback raises
  #   "late_turn"        a turn answers after 300 ms, then as "echo"
  #   "block_interrupt"  "hang", and the interrupt callback blocks
  #   "error_interrupt"  "hang", and an interrupt answers an error
  #   "late_interrupt"   "hang", and an interrupt answers after 100 ms
  #   "block_close"      "echo", and the close callback blocks
  #   "busy"             "echo", and an idle close answers :busy
  #   "late_idle"        "echo", and an idle close answers :ok after 100 ms
  #   "block_idle"       "echo", and the idle close callback blocks
  #   "bad_action"       a turn gives an action that is not one
  #   "bad_reply"        a turn answers `:maybe`
  #   "bad_event"        a turn answers :ok and sends a malformed event
  #   "flood"            "hang"; the message `{:flood, turn_id}` sends
  #                      10,002 deltas and done
  #   "stop"             "hang"; the message `:stop` stops the harness
  @behaviour Helyx.Provider

  @hang ["hang", "flood", "stop", "block_interrupt", "error_interrupt", "late_interrupt"]

  def controller(core), do: :"#{core}_controller"

  @impl true
  def id, do: "conn"

  @impl true
  def turn, do: :external

  @impl true
  def stream(_model, _context, _opts), do: {:error, :connected_only}

  @impl true
  def release(handles, mode, _deadline) do
    for {:report, pid} <- handles, do: send(pid, {:release, mode, handles})
    []
  end

  @impl true
  def harness_init(model, tools, opts) do
    ctl = Process.whereis(controller(opts[:core]))

    if ctl do
      send(ctl, {:conn, :init, self(), {model, tools, opts}})
      Helyx.Tool.hold({:report, ctl})
    end

    case model do
      "block_init" -> Process.sleep(:infinity)
      "fail_init" -> {:error, :no_program}
      _ -> {:ok, %{model: model, ctl: ctl}}
    end
  end

  @impl true
  def harness_request(request, from, %{model: model, ctl: ctl} = state) do
    if ctl, do: send(ctl, {:conn, kind(request), self(), request})
    {:ok, answer(model, request, from), state}
  end

  @impl true
  def harness_info({:late, from, request}, state),
    do: {:ok, answer("echo", request, from), state}

  def harness_info({:finish, turn_id}, state), do: {:ok, [{:event, turn_id, done()}], state}

  def harness_info({:flood, turn_id}, state) do
    deltas = for _ <- 1..10_002, do: {:event, turn_id, {:text_delta, "x"}}
    {:ok, deltas ++ [{:event, turn_id, done()}], state}
  end

  def harness_info(:stop, state), do: {:stop, :gone, state}

  defp kind({kind, _, _}), do: kind
  defp kind({kind, _}), do: kind
  defp kind(:close), do: :close
  defp kind(:idle_close), do: :idle_close

  # The blocks and the raise are the point of this provider.
  @dialyzer {:nowarn_function, answer: 3}
  defp answer("block_turn", {:turn, _, _}, _from), do: Process.sleep(:infinity)
  defp answer("error_turn", {:turn, _, _}, from), do: [{:reply, from, {:error, :refused}}]
  defp answer("crash_turn", {:turn, _, _}, _from), do: raise("turn crashed")
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
  defp answer("busy", :idle_close, from), do: [{:reply, from, :busy}]
  defp answer("late_idle", :idle_close = request, from), do: later(from, request, 100)
  defp answer("block_idle", :idle_close, _from), do: Process.sleep(:infinity)

  defp answer(model, {:turn, id, _}, from) when model in @hang,
    do: [{:reply, from, :ok}, {:event, id, {:text_delta, "so far"}}]

  defp answer(_model, {:turn, id, context}, from) do
    text = "echo:#{context.system}|#{Helyx.Message.text(List.last(context.messages))}"
    [{:reply, from, :ok}, {:event, id, {:text_delta, text}}, {:event, id, done()}]
  end

  defp answer(_model, _request, from), do: [{:reply, from, :ok}]

  defp later(from, request, ms) do
    Process.send_after(self(), {:late, from, request}, ms)
    []
  end

  defp done, do: {:done, %{stop_reason: :end_turn, usage: %{}}}
end

defmodule Helyx.Test.PrepareContext do
  @moduledoc false
  # Sets the system prompt to "prepared", unless the last user message is
  # "block_prepare" (the build blocks), "raise_prepare" (it raises),
  # "nil_build" (it returns nil), "bad_build" (it returns a map),
  # "forged_build" (a struct without :system), "bad_system" (a system
  # prompt that is not a string), or "bad_messages_build" (the messages
  # are not a list).
  @behaviour Helyx.ModelContext

  @impl true
  def build(context, _opts) do
    case context.messages |> List.last() |> Helyx.Message.text() do
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
