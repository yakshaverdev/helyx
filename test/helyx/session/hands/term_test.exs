defmodule Helyx.Session.Hands.TermTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Helyx.{Context, Message, Usage}
  alias Helyx.Session.Hands.Term
  alias Helyx.Session.Input

  @id "0123456789ab"
  @call %Message.ToolCall{id: "call-1", name: "read", arguments: %{"path" => "a"}}
  @tool_spec %{name: "read", description: "Read a file", parameters: %{"type" => "object"}}
  @context %{session_id: @id, model: "fake/echo", provider_opts: [x: 1], model_context: nil}
  @usage %Usage{input: 1, output: 2, cost: 0.5, cost_kind: :list}

  @message %Message{
    role: :user,
    content: [%Message.Text{text: "hi"}],
    id: @id,
    origin: %{kind: :user, id: nil}
  }

  @block %{"kind" => "note", "text" => "hi"}

  # One valid term of each kind, with a field that its check refuses and a
  # field that the term cannot do without.
  defp fixtures do
    [
      %{
        term: %{
          t: :open,
          instance: @id,
          session: @id,
          only: ["read"],
          provider_opts: [x: 1],
          max_output_tokens: 4_096
        },
        wrong: {"only", :not_a_list},
        missing: "only"
      },
      %{
        term: %{t: :call, instance: @id, turn: @id, call: @call, context: @context},
        wrong: {"call", %{"id" => "call-1", "name" => "read"}},
        missing: "context"
      },
      %{term: %{t: :taken, instance: @id, id: @id}, wrong: {"id", ""}, missing: "id"},
      %{term: %{t: :go, instance: @id, task: @id}, wrong: {"task", 1}, missing: "task"},
      %{
        term: %{
          t: :settle,
          instance: @id,
          ref: @id,
          turn: @id,
          input: %{session_id: @id, turn_id: @id, stop_reason: :end_turn, cwd: "/tmp"},
          context: @context
        },
        wrong: {"input", %{}},
        missing: "ref"
      },
      %{
        term: %{
          t: :approve,
          instance: @id,
          turn: @id,
          call: @call,
          context: @context,
          provider: "fake"
        },
        wrong: {"provider", ""},
        missing: "provider"
      },
      %{
        term: %{
          t: :provider_start,
          instance: @id,
          provider: "fake",
          id: @id,
          model: "fake/echo",
          tools: [@tool_spec],
          session: @id,
          resume_id: nil,
          resume_usage: @usage
        },
        wrong: {"tools", :not_a_list},
        missing: "resume_id"
      },
      %{term: %{t: :provider_go, instance: @id, id: @id}, wrong: {"id", ""}, missing: "id"},
      %{
        term: %{
          t: :provider_request,
          instance: @id,
          id: @id,
          from: @id,
          request: %{kind: :interrupt, turn: @id},
          ms: 5_000
        },
        wrong: {"ms", 0},
        missing: "request"
      },
      %{
        term: %{t: :provider_stop, instance: @id, id: @id, reason: "aborted"},
        wrong: {"reason", <<0xFF>>},
        missing: "reason"
      },
      %{term: %{t: :cancel, instance: @id, turn: @id}, wrong: {"turn", ""}, missing: "turn"},
      %{term: %{t: :revoke, instance: @id, turn: @id}, wrong: {"turn", ""}, missing: "turn"},
      %{
        term: %{t: :stop, instance: @id, release_ms: 20_000},
        wrong: {"release_ms", 0},
        missing: "release_ms"
      },
      %{
        term: %{t: :read, instance: @id, read: :read, paths: ["/tmp/a"], max_bytes: 4_096},
        wrong: {"paths", ["ok", ""]},
        missing: "max_bytes"
      },
      %{
        term: %{
          t: :result,
          instance: @id,
          turn: @id,
          call: "call-1",
          status: :ok,
          text: "hi",
          ui_blocks: [@block],
          started: false,
          task: nil
        },
        wrong: {"status", "nope"},
        missing: "task"
      },
      %{
        term: %{t: :background_end, instance: @id, id: @id, message: @message},
        wrong: {"message", %{"role" => "user"}},
        missing: "message"
      },
      %{
        term: %{t: :asker, instance: @id, turn: @id, task: @id, asker: {:tool, "call-1"}},
        wrong: {"asker", %{"kind" => "nope", "id" => @id}},
        missing: "asker"
      },
      %{
        term: %{t: :ask, instance: @id, task: @id, tool: "read", request: %{"q" => "?"}},
        wrong: {"request", []},
        missing: "tool"
      },
      %{
        term: %{t: :show, instance: @id, task: @id, call: "call-1", key: "k", block: @block},
        wrong: {"key", ""},
        missing: "block"
      },
      %{term: %{t: :task_down, instance: @id, task: @id}, wrong: {"task", ""}, missing: "task"},
      %{term: %{t: :transcript, instance: @id, task: @id}, wrong: {"task", ""}, missing: "task"},
      %{term: %{t: :provider_ready, instance: @id, id: @id}, wrong: {"id", ""}, missing: "id"},
      %{term: %{t: :provider_exit, instance: @id, id: @id}, wrong: {"id", ""}, missing: "id"},
      %{
        term: %{
          t: :provider_reply,
          instance: @id,
          id: @id,
          from: @id,
          kind: :turn,
          value: :ok
        },
        wrong: {"kind", "nope"},
        missing: "value"
      },
      %{
        term: %{
          t: :provider_event,
          instance: @id,
          id: @id,
          turn: @id,
          event: %{kind: :stream, event: %{kind: :text_delta, text: "hi"}}
        },
        wrong: {"event", %{"kind" => "nope"}},
        missing: "event"
      },
      %{
        term: %{t: :need_context, instance: @id, id: @id, turn: @id, overflow: false},
        wrong: {"overflow", "false"},
        missing: "overflow"
      },
      %{
        term: %{t: :provider_down, instance: @id, id: @id, reason: "provider_timeout"},
        wrong: {"reason", <<0xFF>>},
        missing: "reason"
      },
      %{
        term: %{
          t: :settle_answer,
          instance: @id,
          ref: @id,
          answer: {:continue, "MyApp.Hook", "go on"}
        },
        wrong: {"answer", %{"kind" => "nope"}},
        missing: "answer"
      },
      %{
        term: %{
          t: :approval_result,
          instance: @id,
          turn: @id,
          call: "call-1",
          decision: {:deny, "no"}
        },
        wrong: {"decision", %{"kind" => "nope"}},
        missing: "decision"
      },
      %{
        term: %{
          t: :hook_answer,
          instance: @id,
          turn: @id,
          record: %{
            point: :after_tool,
            call_id: "call-1",
            hook: "MyApp.Hook",
            outcome: {:answer, {:replace, {:ok, "new"}}},
            call: %{tool: "read", arguments: "{}", arguments_cut: false},
            task: @id
          }
        },
        wrong: {"record", %{}},
        missing: "record"
      },
      %{
        term: %{
          t: :open_answer,
          instance: @id,
          specs: [@tool_spec],
          concurrent: ["read"],
          providers: ["fake"],
          hooks: %{before_tool: [{"MyApp.Hook", 5_000}]},
          folder: "/tmp"
        },
        wrong: {"folder", <<0xFF>>},
        missing: "folder"
      },
      %{
        term: %{t: :ask_answer, instance: @id, ok: true, answer: %{"q" => "a"}},
        wrong: {"answer", "not an object"},
        missing: "answer"
      },
      %{
        term: %{t: :show_answer, instance: @id, result: :too_many},
        wrong: {"result", "nope"},
        missing: "result"
      },
      %{
        term: %{t: :transcript_answer, instance: @id, messages: [@message]},
        wrong: {"messages", "no"},
        missing: "messages"
      },
      %{
        term: %{t: :provider_start_answer, instance: @id, id: @id, ok: true},
        wrong: {"id", ""},
        missing: "id"
      },
      %{
        term: %{t: :cancel_answer, instance: @id, result: :ok},
        wrong: {"error", 1},
        missing: "result"
      },
      %{
        term: %{t: :revoke_answer, instance: @id, ids: [@id], error: nil},
        wrong: {"ids", ["ok", ""]},
        missing: "error"
      },
      %{
        term: %{t: :stop_answer, instance: @id, unconfirmed: ["a handle"]},
        wrong: {"unconfirmed", "no"},
        missing: "unconfirmed"
      },
      %{
        term: %{
          t: :read_answer,
          instance: @id,
          files: [%{path: "/tmp/a", text: "hi"}, %{path: "/tmp/b", error: :enoent}]
        },
        wrong: {"files", [%{"path" => "/x"}]},
        missing: "files"
      }
    ]
  end

  defp encode!(term) do
    {:ok, map} = Term.encode(term)
    map
  end

  defp size(term), do: term |> encode!() |> Message.encoded_size() |> elem(1)

  defp taken(instance, id), do: %{t: :taken, instance: instance, id: id}

  property "every term round-trips" do
    terms = Enum.map(fixtures(), & &1.term)
    id = StreamData.string([?a..?z, ?0..?9], min_length: 1, max_length: Term.max_id_bytes())
    text = StreamData.string([?a..?z, ?0..?9], min_length: 1, max_length: 32)

    check all(
            term <- StreamData.one_of(Enum.map(terms, &StreamData.constant/1)),
            id <- id,
            text <- text
          ) do
      term = vary(term, id, text)
      assert {:ok, map} = Term.encode(term)
      assert {:ok, ^term} = Term.decode(map)
    end
  end

  # Vary the ids and the texts of a fixture, where it has them.
  defp vary(term, id, text) do
    term = vary_fields(term, [:instance, :turn, :task, :id, :ref, :from, :call], id)
    vary_fields(term, [:text, :reason, :tool], text)
  end

  defp vary_fields(term, keys, value) do
    Enum.reduce(keys, term, fn key, term ->
      if is_binary(Map.get(term, key)), do: Map.put(term, key, value), else: term
    end)
  end

  test "every term refuses a wrong field" do
    for %{term: term, wrong: {key, value}} <- fixtures() do
      map = Map.put(encode!(term), key, value)
      assert Term.decode(map) == :error, "a wrong #{key} in #{term.t}"
    end
  end

  test "every term refuses a missing field" do
    for %{term: term, missing: key} <- fixtures() do
      map = Map.delete(encode!(term), key)
      assert Term.decode(map) == :error, "a missing #{key} in #{term.t}"
    end
  end

  test "every kind has a fixture" do
    kinds = fixtures() |> Enum.map(& &1.term.t) |> Enum.sort()
    assert kinds == Enum.sort(Term.kinds())
  end

  test "an id of 64 bytes is accepted, and 65 or 0 bytes is refused" do
    max = Term.max_id_bytes()
    id64 = String.duplicate("a", max)
    id65 = String.duplicate("a", max + 1)

    assert {:ok, _term} = Term.check(taken(id64, id64))
    assert :error = Term.check(taken(id65, id64))
    assert :error = Term.check(taken(id64, id65))
    assert :error = Term.check(taken("", @id))
    assert :error = Term.check(taken(@id, ""))

    assert {:ok, _term} = Term.decode(%{"t" => "hands.taken", "instance" => id64, "id" => id64})
    assert :error = Term.decode(%{"t" => "hands.taken", "instance" => id65, "id" => id64})
    assert :error = Term.decode(%{"t" => "hands.taken", "instance" => "", "id" => id64})
    assert :error = Term.decode(%{"t" => "hands.taken", "instance" => id64, "id" => ""})
  end

  test "a multibyte id counts bytes" do
    max = Term.max_id_bytes()
    id64 = String.duplicate("é", div(max, 2))
    id65 = id64 <> "a"
    id66 = String.duplicate("é", div(max, 2) + 1)

    assert byte_size(id64) == max
    assert {:ok, _term} = Term.check(taken(id64, id64))
    assert :error = Term.check(taken(id65, id64))
    assert :error = Term.check(taken(id66, id64))
  end

  test "a turn that the provider started has the resume id bound" do
    turn = String.duplicate("a", 256)

    term = %{
      t: :provider_event,
      instance: @id,
      id: @id,
      turn: turn,
      event: %{kind: :stream, event: %{kind: :turn_start}}
    }

    assert {:ok, _term} = Term.check(term)
    assert :error = Term.check(%{term | turn: String.duplicate("a", 257)})
  end

  test "a registration id has the origin id bound" do
    max = Term.max_plugin_bytes()
    provider = String.duplicate("a", max)

    term = fn provider ->
      %{
        t: :approve,
        instance: @id,
        turn: @id,
        call: @call,
        context: @context,
        provider: provider
      }
    end

    assert {:ok, _term} = Term.check(term.(provider))
    assert :error = Term.check(term.(provider <> "a"))
    assert :error = Term.check(term.(""))
  end

  test "invalid UTF-8 is refused" do
    bad = <<0xFF>>

    assert :error = Term.encode(taken(bad, @id))
    assert :error = Term.decode(%{"t" => "hands.taken", "instance" => bad, "id" => @id})
    assert :error = Term.encode(%{t: :provider_stop, instance: @id, id: @id, reason: bad})
  end

  test "a term with only its t is refused, not crashed" do
    for tag <- Term.kinds() do
      assert :error = Term.check(%{t: tag}), "a bare #{tag}"
    end

    for tag <- [:result, :provider_start] do
      fields = Map.new(1..8, &{"field_#{&1}", &1})
      assert :error = Term.check(Map.merge(fields, %{t: tag})), "another #{tag}"
    end
  end

  test "an unknown t is refused" do
    assert :error = Term.decode(%{"t" => "hands.nope", "instance" => @id})
    assert :error = Term.decode(%{"t" => "nope"})
    assert :error = Term.decode(%{})
  end

  test "a term of the other direction does not fit" do
    result = %{
      t: :result,
      instance: @id,
      turn: @id,
      call: "call-1",
      status: :ok,
      text: "hi",
      ui_blocks: [],
      started: false,
      task: nil
    }

    assert Term.fits?(result, :hands_to_session) == :ok
    assert Term.fits?(result, :session_to_hands) == :error
  end

  @tag :slow
  test "a session to hands term fits its byte limit at the bound, one under, and one over" do
    limit = Term.limit(:session_to_hands)
    term = fn text -> %{t: :provider_stop, instance: @id, id: @id, reason: text} end
    room = limit.bytes - size(term.(""))
    full = :binary.copy("a", room + 1)
    at = term.(binary_part(full, 0, room))

    assert size(at) == limit.bytes
    assert Term.fits?(at, :session_to_hands) == :ok
    assert Term.fits?(term.(binary_part(full, 0, room - 1)), :session_to_hands) == :ok
    assert Term.fits?(term.(full), :session_to_hands) == :error
  end

  @tag :slow
  test "a hands to session term fits its byte limit at the bound, one under, and one over" do
    limit = Term.limit(:hands_to_session)
    term = fn text -> %{t: :provider_down, instance: @id, id: @id, reason: text} end
    room = limit.bytes - size(term.(""))
    full = :binary.copy("a", room + 1)
    at = term.(binary_part(full, 0, room))

    assert size(at) == limit.bytes
    assert Term.fits?(at, :hands_to_session) == :ok
    assert Term.fits?(term.(binary_part(full, 0, room - 1)), :hands_to_session) == :ok
    assert Term.fits?(term.(full), :hands_to_session) == :error
  end

  test "a session to hands term fits its value limit at the bound, one under, and one over" do
    limit = Term.limit(:session_to_hands)

    term = fn names ->
      %{
        t: :open,
        instance: @id,
        session: @id,
        only: List.duplicate("a", names),
        provider_opts: [],
        max_output_tokens: nil
      }
    end

    room = limit.values - Term.values(encode!(term.(0)))
    at = term.(room)

    assert Term.values(encode!(at)) == limit.values
    assert Term.fits?(at, :session_to_hands) == :ok
    assert Term.fits?(term.(room - 1), :session_to_hands) == :ok
    assert Term.fits?(term.(room + 1), :session_to_hands) == :error
  end

  @tag :slow
  test "a hands to session term fits its value limit at the bound, one under, and one over" do
    limit = Term.limit(:hands_to_session)

    term = fn providers ->
      %{
        t: :open_answer,
        instance: @id,
        specs: [],
        concurrent: [],
        providers: List.duplicate("a", providers),
        hooks: %{},
        folder: "/tmp"
      }
    end

    room = limit.values - Term.values(encode!(term.(0)))
    at = term.(room)

    assert Term.values(encode!(at)) == limit.values
    assert Term.fits?(at, :hands_to_session) == :ok
    assert Term.fits?(term.(room - 1), :hands_to_session) == :ok
    assert Term.fits?(term.(room + 1), :hands_to_session) == :error
  end

  test "a read takes at most the path count and the path bytes" do
    paths = Term.max_paths()
    bytes = Term.max_path_bytes()

    read = fn list ->
      %{t: :read, instance: @id, read: :read, paths: list, max_bytes: 4_096}
    end

    path = String.duplicate("a", bytes)
    assert {:ok, _term} = Term.check(read.(List.duplicate(path, paths)))
    assert :error = Term.check(read.(List.duplicate(path, paths + 1)))
    assert :error = Term.check(read.([path <> "a"]))
  end

  test "an integer of the limit is accepted, and one character more is refused" do
    max = Term.max_integer_chars()

    term = fn number ->
      %{
        t: :open,
        instance: @id,
        session: @id,
        only: nil,
        provider_opts: [x: number],
        max_output_tokens: nil
      }
    end

    at = Integer.pow(10, max - 1)
    over = Integer.pow(10, max)
    negative_at = -(Integer.pow(10, max - 2) * 10 - 1)
    negative_over = -Integer.pow(10, max - 1)
    assert byte_size(Integer.to_string(at)) == max
    assert byte_size(Integer.to_string(negative_at)) == max
    assert byte_size(Integer.to_string(negative_over)) == max + 1

    assert {:ok, _term} = Term.check(term.(at))
    assert {:ok, _term} = Term.check(term.(negative_at))
    assert :error = Term.check(term.(over))
    assert :error = Term.check(term.(negative_over))

    map = encode!(term.(at))
    assert :error = Term.decode(Map.put(map, "provider_opts", [["x", over]]))
  end

  test "the runner-to-server limits are the smaller direction" do
    assert Term.limit(:hands_to_session).bytes < Term.limit(:session_to_hands).bytes
    assert Term.limit(:hands_to_session).values < Term.limit(:session_to_hands).values
  end

  test "a context message needs no id and no origin" do
    message = Message.user("hi")
    checked = round_trip(provider_request(%Context{system: nil, messages: [message], tools: []}))
    assert checked.request.context.messages == [message]

    with_id = %{Message.user("hi") | id: @id}
    checked = round_trip(provider_request(%Context{system: nil, messages: [with_id], tools: []}))
    assert checked.request.context.messages == [with_id]
  end

  test "a context message over the block bound or with a wrong is_error is refused" do
    blocks = List.duplicate(%Message.Text{text: "x"}, Helyx.Session.Turn.max_message_blocks() + 1)
    context = %Context{system: nil, messages: [%Message{role: :user, content: blocks}], tools: []}
    assert :error = Term.check(provider_request(context))

    assistant = %Message{role: :assistant, content: [%Message.Text{text: "x"}], is_error: true}
    assert :error = Term.check(provider_request(%{context | messages: [assistant]}))
  end

  test "a session message over the block bound or with a wrong is_error is refused" do
    blocks = List.duplicate(%Message.Text{text: "x"}, Helyx.Session.Turn.max_message_blocks() + 1)
    user = %Message{role: :user, content: blocks, id: @id, origin: %{kind: :user, id: nil}}

    assert :error =
             Term.check(%{t: :background_end, instance: @id, id: @id, message: user})

    assistant = %Message{role: :assistant, content: [%Message.Text{text: "x"}], is_error: true}

    assert :error =
             Term.check(%{t: :background_end, instance: @id, id: @id, message: assistant})
  end

  test "a hook record keeps the bounds of the code" do
    long = String.duplicate("a", 5_000)

    for {point, outcome} <- [
          {:before_tool, {:answer, {:deny, long}}},
          {:before_tool, {:answer, {:allow, long}}},
          {:before_settle, {:failed, long}}
        ] do
      checked = round_trip(hook_answer(hook_record(point, outcome)))
      assert checked.record.outcome == outcome
    end

    replace = {:answer, {:replace, {:ok, String.duplicate("a", 70_000)}}}
    checked = round_trip(hook_answer(hook_record(:after_tool, replace)))
    assert {:answer, {:replace, {:ok, text}}} = checked.record.outcome
    assert byte_size(text) <= Message.max_result_bytes()
  end

  test "a malformed provider event is refused, not raised" do
    bad_call = %Message.ToolCall{id: "", name: "read", arguments: %{}}

    assert :error =
             Term.check(provider_event(%{kind: :tool_request, call: bad_call, rejection: nil}))

    big = Integer.pow(10, 100)
    call = %Message.ToolCall{id: "call-1", name: "read", arguments: %{"n" => big}}

    assert :error =
             Term.check(provider_event(%{kind: :stream, event: %{kind: :tool_call, call: call}}))

    extra = provider_event(%{kind: :approval, approval: "a", call: "c", extra: 1})
    assert :error = Term.check(extra)
    assert :error = Term.encode(extra)
    assert :error = Term.fits?(extra, :hands_to_session)
  end

  test "a provider tool call event keeps the checked call" do
    checked =
      round_trip(provider_event(%{kind: :stream, event: %{kind: :tool_call, call: @call}}))

    assert checked.event.event == %{kind: :tool_call, call: @call}
  end

  test "a tool request carries its rejection reason" do
    shape = %{kind: :tool_request, call: @call, rejection: "the arguments are over the bound"}
    checked = round_trip(provider_event(shape))
    assert checked.event.rejection == "the arguments are over the bound"
    assert :error = Term.check(provider_event(%{shape | rejection: 1}))
  end

  test "a usage with a cost round-trips" do
    usage = %Usage{input: 1, output: 2, cost: 0.5, cost_kind: :list}

    start = %{
      t: :provider_start,
      instance: @id,
      provider: "fake",
      id: @id,
      model: "m",
      tools: [],
      session: @id,
      resume_id: nil,
      resume_usage: usage
    }

    assert round_trip(start).resume_usage.cost == 0.5

    done = provider_event(%{kind: :end, terminal: %{kind: :done, stop: :end_turn, usage: usage}})
    assert round_trip(done).event.terminal.usage.cost == 0.5

    message = %Message{
      role: :assistant,
      content: [%Message.Text{text: "hi"}],
      id: @id,
      usage: usage
    }

    checked = round_trip(%{t: :background_end, instance: @id, id: @id, message: message})
    assert checked.message.usage.cost == 0.5
  end

  test "a duration, a limit, and a byte count have an upper bound" do
    big = Integer.pow(10, 5_000)

    open = %{
      t: :open,
      instance: @id,
      session: @id,
      only: nil,
      provider_opts: [],
      max_output_tokens: big
    }

    assert :error = Term.check(open)
    assert {:ok, _term} = Term.check(%{open | max_output_tokens: Input.max_output_tokens()})
    assert :error = Term.check(%{open | max_output_tokens: Input.max_output_tokens() + 1})

    assert :error = Term.check(%{t: :stop, instance: @id, release_ms: big})
    assert {:ok, _term} = Term.check(%{t: :stop, instance: @id, release_ms: 20_000})

    read = %{t: :read, instance: @id, read: :read, paths: ["/a"], max_bytes: big}
    assert :error = Term.check(read)

    request = %{
      t: :provider_request,
      instance: @id,
      id: @id,
      from: @id,
      request: %{kind: :interrupt, turn: @id},
      ms: big
    }

    assert :error = Term.check(request)
    assert {:ok, _term} = Term.check(%{request | ms: 5_000})
  end

  test "tool call arguments are an object" do
    for arguments <- [[1], "text", nil, 5] do
      term = %{
        t: :call,
        instance: @id,
        turn: @id,
        call: %{@call | arguments: arguments},
        context: @context
      }

      assert :error = Term.check(term), "arguments #{inspect(arguments)}"
    end

    assert {:ok, _term} =
             Term.check(%{t: :call, instance: @id, turn: @id, call: @call, context: @context})
  end

  test "a check returns the cut value" do
    long = String.duplicate("a", 70_000)

    result = %{
      t: :result,
      instance: @id,
      turn: @id,
      call: "call-1",
      status: :ok,
      text: long,
      ui_blocks: [],
      started: false,
      task: nil
    }

    checked = round_trip(result)
    assert checked.text != long
    assert byte_size(checked.text) <= Message.max_result_bytes()

    checked =
      round_trip(
        provider_event(%{
          kind: :stream,
          event: %{kind: :tool_result, call: "c", result: {:ok, long}}
        })
      )

    assert {:ok, text} = checked.event.event.result
    assert byte_size(text) <= Message.max_result_bytes()

    block = %{"kind" => "note", "text" => long}

    checked =
      round_trip(
        provider_event(%{
          kind: :stream,
          event: %{kind: :ui_block, call: "c", key: "k", block: block}
        })
      )

    {:ok, bytes} = Message.encoded_size(checked.event.event.block)
    assert bytes <= Helyx.UIBlock.max_bytes()

    message = %Message{
      role: :tool_result,
      content: [%Message.Text{text: long}],
      id: @id,
      tool_call_id: "c",
      tool_name: "read",
      is_error: false
    }

    checked = round_trip(%{t: :background_end, instance: @id, id: @id, message: message})
    assert [%Message.Text{text: text}] = checked.message.content
    assert byte_size(text) <= Message.max_result_bytes()
  end

  test "a capability report names the hooks" do
    hooks = %{before_tool: [{"MyApp.Hook", 5_000}], before_settle: [{"Other.Hook", 1}]}

    term = %{
      t: :open_answer,
      instance: @id,
      specs: [],
      concurrent: [],
      providers: [],
      hooks: hooks,
      folder: "/tmp"
    }

    checked = round_trip(term)
    assert checked.hooks == hooks

    assert :error = Term.check(%{term | hooks: %{nope: []}})
    assert :error = Term.check(%{term | hooks: %{before_tool: [{"MyApp.Hook", 0}]}})
  end

  test "values counts the way the wire does" do
    assert Term.values(%{"a" => 1}) == 3
    assert Term.values([1, 2]) == 3
    assert Term.values(1) == 1
    assert Term.values(%{"a" => %{"b" => 1}}) == 5
  end

  test "an atom stop reason in a JSON map is refused" do
    settle = %{
      t: :settle,
      instance: @id,
      ref: @id,
      turn: @id,
      input: %{session_id: @id, turn_id: @id, stop_reason: :end_turn, cwd: "/tmp"},
      context: @context
    }

    map = encode!(settle)
    input = Map.put(map["input"], "stop_reason", :end_turn)
    assert :error = Term.decode(Map.put(map, "input", input))

    done = provider_event(%{kind: :end, terminal: %{kind: :done, stop: :end_turn, usage: nil}})
    map = encode!(done)
    terminal = Map.put(map["event"]["terminal"], "stop", :end_turn)
    assert :error = Term.decode(update_in(map["event"], &Map.put(&1, "terminal", terminal)))
  end

  defp provider_event(event),
    do: %{t: :provider_event, instance: @id, id: @id, turn: @id, event: event}

  defp provider_request(context) do
    %{
      t: :provider_request,
      instance: @id,
      id: @id,
      from: @id,
      request: %{kind: :turn, turn: @id, context: context},
      ms: 5_000
    }
  end

  defp hook_answer(record), do: %{t: :hook_answer, instance: @id, turn: @id, record: record}

  defp hook_record(point, outcome) do
    %{
      point: point,
      call_id: if(point == :before_settle, do: nil, else: "call-1"),
      hook: "MyApp.Hook",
      outcome: outcome,
      call: %{tool: "read", arguments: "{}", arguments_cut: false},
      task: @id
    }
  end

  defp round_trip(term) do
    assert {:ok, checked} = Term.check(term)
    assert {:ok, map} = Term.encode(term)
    assert {:ok, ^checked} = Term.decode(map)
    checked
  end
end
