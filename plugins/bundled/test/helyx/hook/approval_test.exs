defmodule Helyx.Hook.ApprovalTest do
  # The approval gate (docs/features/approval-gate.md): its rules and
  # config with the config that the test passes, its request at the cut
  # bounds, and its ask in a session. Not async: the env key
  # `:approval_hook` of `helyx_plugins` is global.
  use ExUnit.Case, async: false

  import Helyx.Test.Events, only: [collect_until: 1, of_type: 2]

  alias Helyx.Hook.Approval
  alias Helyx.Message
  alias Helyx.Message.ToolCall
  alias Helyx.Provider.Fake
  alias Helyx.Session

  @moduletag :tmp_dir

  setup do
    on_exit(fn -> Application.delete_env(:helyx_plugins, :approval_hook) end)
  end

  defp put_env(env), do: Application.put_env(:helyx_plugins, :approval_hook, env)

  defp call(tool, provider \\ nil, arguments \\ %{"path" => "a.txt"}),
    do: %{
      tool: tool,
      provider: provider,
      arguments: arguments,
      cwd: ".",
      session_id: "s",
      turn_id: "t",
      call_id: "c"
    }

  describe "the rules" do
    test "a rule of the tool decides, and the default decides with none" do
      env = [rules: [[tool: "read", action: :allow], [tool: "bash", action: :deny]]]

      assert Approval.decide(call("read"), env) == {:allow, "the rule for read allows the call"}
      assert Approval.decide(call("bash"), env) == {:deny, "the rule for bash denies the call"}

      assert Approval.decide(call("write"), env ++ [default: :deny]) ==
               {:deny, "no rule names write, and the default denies the call"}

      assert Approval.decide(call("write"), env ++ [default: :allow]) ==
               {:allow, "no rule names write, and the default allows the call"}
    end

    test "the provider of a rule names the provider's own tool; nil a Helyx tool" do
      env = [
        rules: [
          [tool: "fileChange", provider: "codex", action: :deny],
          [tool: "fileChange", provider: nil, action: :allow]
        ],
        default: :allow
      ]

      assert Approval.decide(call("fileChange", "codex"), env) ==
               {:deny, "the rule for fileChange of codex denies the call"}

      assert Approval.decide(call("fileChange"), env) ==
               {:allow, "the rule for fileChange allows the call"}

      assert Approval.decide(call("fileChange", "other"), env) ==
               {:allow, "no rule names fileChange of other, and the default allows the call"}
    end

    test "of the rules that match, a deny wins over an ask, and an ask over an allow" do
      rules = for action <- [:allow, :deny, :ask], do: [tool: "bash", action: action]
      assert {:deny, _} = Approval.decide(call("bash"), rules: rules)
      assert {:deny, _} = Approval.decide(call("bash"), rules: Enum.reverse(rules))

      # An ask over an allow: the ask runs, which raises outside a hook Task.
      rules = [[tool: "bash", action: :allow], [tool: "bash", action: :ask]]

      assert_raise ArgumentError, "context/0 runs only in a tool call", fn ->
        Approval.decide(call("bash"), rules: rules)
      end
    end

    test "no config, and no rule that matches, ask by default" do
      for env <- [nil, [], [rules: [[tool: "read", action: :allow]]]] do
        assert_raise ArgumentError, "context/0 runs only in a tool call", fn ->
          Approval.decide(call("bash"), env)
        end
      end
    end

    test "a broken config fails the hook, with the path of its first bad value" do
      for {env, path} <- [
            {:bad, [:approval_hook]},
            {[rules: [], rules: []], [:approval_hook]},
            {[mode: :ask], [:approval_hook]},
            {[rules: nil], [:approval_hook, :rules]},
            {[rules: [[tool: "a", action: :allow] | :tail]], [:approval_hook, :rules]},
            {[default: nil], [:approval_hook, :default]},
            {[default: :maybe], [:approval_hook, :default]},
            {[limit_ms: 0], [:approval_hook, :limit_ms]},
            {[rules: [:bad]], [:approval_hook, :rules, 0]},
            {[rules: [[tool: "a", action: :allow], [tool: "b"]]],
             [:approval_hook, :rules, 1, :action]},
            {[rules: [[action: :allow]]], [:approval_hook, :rules, 0, :tool]},
            {[rules: [[tool: nil, action: :allow]]], [:approval_hook, :rules, 0, :tool]},
            {[rules: [[tool: "a", provider: 1, action: :allow]]],
             [:approval_hook, :rules, 0, :provider]},
            {[rules: [[tool: "a", action: "allow"]]], [:approval_hook, :rules, 0, :action]},
            {[rules: [[tool: "a", action: :allow, action: :deny]]], [:approval_hook, :rules, 0]},
            {[rules: [[tool: "a", action: :allow, tools: ["b"]]]], [:approval_hook, :rules, 0]}
          ] do
        message = "its config :approval_hook is invalid: #{inspect(path)}"
        assert_raise ArgumentError, message, fn -> Approval.decide(call("read"), env) end
      end
    end

    test "limit/1 gives limit_ms as the config has it, else 600,000" do
      put_env(limit_ms: 1_500)
      assert Approval.limit(:before_tool) == 1_500

      for env <- [nil, :bad, [], [rules: []]] do
        put_env(env)
        assert Approval.limit(:before_tool) == 600_000
      end

      put_env(limit_ms: nil)
      assert Approval.limit(:before_tool) == nil
    end
  end

  describe "the request" do
    test "an approval block of the call" do
      assert Approval.request(call("bash", nil, %{"command" => "mix test"})) == %{
               "kind" => "approval",
               "text" => "allow bash?",
               "tool" => "bash",
               "provider" => nil,
               "arguments" => ~s({"command":"mix test"})
             }

      assert %{"text" => "allow fileChange of codex?", "provider" => "codex"} =
               Approval.request(call("fileChange", "codex", %{}))
    end

    test "tool and provider are cut at 256 bytes, the arguments at 16,384" do
      max = Approval.max_name_bytes()
      at = String.duplicate("a", max)
      refute Map.has_key?(Approval.request(call(at, at, %{})), "cut")

      assert %{"tool" => ^at, "provider" => nil, "cut" => true} =
               Approval.request(call(at <> "b", nil, %{}))

      assert %{"tool" => "t", "provider" => ^at, "cut" => true} =
               Approval.request(call("t", at <> "b", %{}))

      # A multibyte character that the cut splits is dropped.
      request = Approval.request(call(String.duplicate("é", 129), nil, %{}))
      assert request["tool"] == String.duplicate("é", 128)
      assert request["cut"] == true

      # The JSON text `{"k":"…"}` has 8 bytes beside the value.
      bytes = Approval.max_arguments_bytes()
      fits = %{"k" => String.duplicate("a", bytes - 8)}
      assert Approval.request(call("t", nil, fits))["arguments"] == JSON.encode!(fits)
      refute Map.has_key?(Approval.request(call("t", nil, fits)), "cut")

      over = %{"k" => String.duplicate("a", bytes - 7)}
      request = Approval.request(call("t", nil, over))
      assert request["cut"] == true
      assert byte_size(request["arguments"]) == bytes
    end

    test "a cut of the arguments that splits a character drops it" do
      # `{"kk":"` is 7 bytes, so the cut at 16,384 splits an é.
      request = Approval.request(call("t", nil, %{"kk" => String.duplicate("é", 8_200)}))
      assert request["cut"] == true
      assert byte_size(request["arguments"]) == Approval.max_arguments_bytes() - 1
      assert String.valid?(request["arguments"])
    end

    test "the largest request is a UI block under the bound of an ask" do
      # Each byte a control character, six bytes of JSON; each byte of the
      # arguments text a quote, two.
      name = String.duplicate(<<1>>, 1_000)
      request = Approval.request(call(name, name, %{"k" => String.duplicate(~s("), 20_000)}))
      assert request["cut"] == true
      assert Helyx.UIBlock.envelope?(request)

      assert Helyx.Session.Input.json_object(request, Helyx.Session.Ask.max_request_bytes()) ==
               :ok

      assert byte_size(JSON.encode!(request)) < 40_000
    end
  end

  describe "in a session" do
    setup %{tmp_dir: dir} do
      core = :"approval_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Helyx.Core, name: core, plugins: [Fake, Helyx.Tool.Read, Helyx.Hook.Approval]}
      )

      File.write!(Path.join(dir, "a.txt"), "the file\n")
      %{core: core}
    end

    defp run(core, dir, subscribe_opts) do
      model = "approval_#{System.unique_integer([:positive])}"
      call = %ToolCall{id: "r1", name: "read", arguments: %{"path" => "a.txt"}}
      :ok = Fake.script(core, model, [[call], ["Done."]])
      {:ok, session} = Session.start(core, model: "fake/#{model}", cwd: dir)
      {:ok, _snapshot, _ref} = Session.subscribe(session, subscribe_opts)
      :ok = Session.prompt(session, "go")
      session
    end

    defp result(events) do
      [%{message: message}] = of_type(events, :tool_execution_end)
      {message.is_error, Message.text(message)}
    end

    test "the user allows the call, and it runs", %{core: core, tmp_dir: dir} do
      session = run(core, dir, answers: true)
      [ask] = of_type(collect_until(:ask), :ask)
      assert ask.tool == "read"

      assert ask.request == %{
               "kind" => "approval",
               "text" => "allow read?",
               "tool" => "read",
               "provider" => nil,
               "arguments" => ~s({"path":"a.txt"})
             }

      assert Session.answer(session, ask.ask_id, %{"decision" => "allow"}) == :ok
      {false, text} = result(collect_until(:turn_end))
      assert text =~ "the file"
    end

    test "the user denies the call, and any other answer denies it", %{core: core, tmp_dir: dir} do
      for {answer, reason} <- [
            {%{"decision" => "deny"}, "the user denied the call"},
            {%{"decision" => "yes"}, "the answer of the client was not an allow or a deny"},
            {%{"decision" => "allow", "x" => 1},
             "the answer of the client was not an allow or a deny"},
            {%{}, "the answer of the client was not an allow or a deny"}
          ] do
        session = run(core, dir, answers: true)
        [ask] = of_type(collect_until(:ask), :ask)
        assert Session.answer(session, ask.ask_id, answer) == :ok

        assert result(collect_until(:turn_end)) ==
                 {true, "the hook Helyx.Hook.Approval denied the call: #{reason}"}
      end
    end

    test "with no client that can answer, the call is denied at once", %{core: core, tmp_dir: dir} do
      run(core, dir, [])
      events = collect_until(:turn_end)
      assert of_type(events, :ask) == []

      assert result(events) ==
               {true,
                "the hook Helyx.Hook.Approval denied the call: no user can approve the call " <>
                  "in this run: no client that can answer is attached, as in a print run or " <>
                  "the session of a sub-agent; try another way"}
    end

    test "a rule allows or denies with no ask", %{core: core, tmp_dir: dir} do
      put_env(rules: [[tool: "read", action: :deny]])
      run(core, dir, answers: true)
      events = collect_until(:turn_end)
      assert of_type(events, :ask) == []

      assert result(events) ==
               {true,
                "the hook Helyx.Hook.Approval denied the call: the rule for read denies the call"}

      put_env(rules: [[tool: "read", action: :allow]])
      run(core, dir, answers: true)
      assert {false, "the file" <> _} = result(collect_until(:turn_end))
    end

    test "a broken config denies the call", %{core: core, tmp_dir: dir} do
      put_env(default: :maybe)
      run(core, dir, answers: true)

      assert result(collect_until(:turn_end)) ==
               {true,
                "the hook Helyx.Hook.Approval failed: its config :approval_hook is invalid: " <>
                  "[:approval_hook, :default]; the call was not run"}
    end
  end

  describe "the reply of the ask" do
    # The session gives `:not_running` when the result of the call joins
    # the transcript while the gate asks, as at a taken steer
    # (docs/features/ui-blocks.md); the provider that does it is a test
    # plugin of Core, so the answer to each reply is tested here.
    test "each reply of Helyx.Hook.ask/1 gives its answer" do
      assert Approval.asked({:ok, %{"decision" => "allow"}}) ==
               {:allow, "the user allowed the call"}

      assert Approval.asked({:ok, %{"decision" => "deny"}}) == {:deny, "the user denied the call"}
      assert Approval.asked({:error, :not_running}) == {:deny, "the call no longer runs"}

      assert {:deny, "no user can approve the call in this run" <> _} =
               Approval.asked({:error, :no_client})
    end
  end

  describe "the limit" do
    test "Core refuses a bad limit_ms at its start" do
      for ms <- [600_001, 0, nil] do
        put_env(limit_ms: ms)
        name = :"approval_#{System.unique_integer([:positive])}"

        assert Helyx.Core.start_link(name: name, plugins: [Fake, Helyx.Hook.Approval]) ==
                 {:error, {:invalid_hook_limit, Helyx.Hook.Approval}}
      end
    end

    # The limit is read at Core start, so the env is set before it.
    test "past its limit with no answer, the call is denied and the ask ends", %{tmp_dir: dir} do
      put_env(limit_ms: 300)
      core = :"approval_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Helyx.Core, name: core, plugins: [Fake, Helyx.Tool.Read, Helyx.Hook.Approval]}
      )

      File.write!(Path.join(dir, "a.txt"), "the file\n")
      run(core, dir, answers: true)
      events = collect_until(:turn_end)
      [ask] = of_type(events, :ask)
      assert [%{ask_id: id, outcome: :ended}] = of_type(events, :ask_end)
      assert id == ask.ask_id

      assert result(events) ==
               {true,
                "the hook Helyx.Hook.Approval failed: it ran past its limit of 300 ms; " <>
                  "the call was not run"}
    end
  end
end
