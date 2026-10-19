defmodule Helyx.Provider.ClaudeCode.EnvTest do
  # The `env` option (docs/features/harness-no-state.md, "The environment
  # of the program"). No test prints a value: the fake compares them and
  # writes words.
  use ExUnit.Case, async: true

  import Helyx.Test.ClaudeCodeFake
  import Helyx.Test.HarnessDriver

  alias Helyx.Message
  alias Helyx.Provider.ClaudeCode

  @moduletag :tmp_dir

  setup {Helyx.Test.ClaudeCodeFake, :setup_fake}

  @value "a b=c é"

  defp answer(text), do: %Message{role: :assistant, content: [%Message.Text{text: text}]}

  # Program `n` writes `env.n`: `map` when it has the value of the map,
  # `home` when it has `home` in place of the inherited HOME, `folder`
  # when its state folder is `home`, and `inherited` when it has the PATH
  # that the test helper gives the BEAM. Then it runs `tail`.
  defp check(bin, n, home, tail \\ "") do
    File.write!(Path.join(bin, "start.#{n}"), """
    { [ "$HELYX_TEST_751" = '#{@value}' ] && echo map; [ "$HOME" = '#{home}' ] && echo home
      [ "$CLAUDE_CONFIG_DIR" = '#{home}' ] && echo folder
      case "$PATH" in *test_dispatch*) echo inherited ;; esac; } > "$d/env.#{n}"
    #{tail}
    """)
  end

  defp seen(bin, n), do: bin |> Path.join("env.#{n}") |> File.read!() |> String.split()

  defp run(state, system, messages) do
    context = %Helyx.Context{system: system, messages: messages}
    {_from, actions, state} = request(state, {:turn, "t1", context})
    {actions, state} = pump(ClaudeCode, state, actions, &ended?/1)
    {events_of(actions), state}
  end

  test "every launch gets the map on top of the inherited environment",
       %{bin: bin, work: work} do
    # Program 1 has lost the stored harness session, program 2 is the fresh
    # one in its place, and program 3 resumes it after a prompt change.
    script(bin, "lost", [lost(sid())], "exit 1\n")
    check(bin, 1, work, ~s(. "$d/lost"))
    for n <- [2, 3], do: check(bin, n, work)
    turn(bin, 2, 1, reply("two"))
    turn(bin, 3, 1, reply("three"))

    env = %{"HELYX_TEST_751" => @value, "HOME" => work, "CLAUDE_CONFIG_DIR" => work}
    state = harness(work, env: env, resume_id: stored(sid()))
    {_events, state} = run(state, "A", [Message.user("x")])
    {events, state} = run(state, "B", [Message.user("x"), answer("two"), Message.user("y")])
    closed(state)

    assert [{:text_delta, "three"} | _] = events
    assert programs(bin) == "3"
    for n <- 1..3, do: assert(seen(bin, n) == ["map", "home", "folder", "inherited"])
  end

  test "a name that is not a shell identifier or a value that is empty, not UTF-8, or has a NUL fails the init with the option only",
       %{work: work} do
    for bad <- [
          nil,
          [{"A", "v"}],
          %{"" => "v"},
          %{"A=B" => "v"},
          %{"A\0B" => "v"},
          %{"A-B" => "v"},
          %{"1A" => "v"},
          %{"IFS" => "v"},
          %{"É" => "v"},
          %{"A" => ""},
          %{"A" => "v\0w"},
          %{"A" => <<0xFF>>},
          %{<<0xFF>> => "v"},
          %{a: "v"},
          %{"A" => 1},
          %URI{}
        ] do
      assert ClaudeCode.init("haiku", [], cwd: work, env: bad) ==
               {:error, {:invalid_option, :env}}
    end
  end

  # The list of docs/features/harness-no-state.md, "The check": the shell
  # of the launch sets these names itself.
  @shell_names ~w(BASH BASHOPTS BASH_COMMAND BASH_EXECUTION_STRING BASH_SUBSHELL BASH_VERSINFO
                  BASH_VERSION CDPATH COMP_WORDBREAKS ENV HISTCMD IFS LINENO OLDPWD OPTERR OPTIND
                  POSIXLY_CORRECT PPID PS1 PS2 PS4 PWD RANDOM SHELLOPTS SHLVL)

  test "each name that the shell sets itself fails the init", %{work: work} do
    accepted =
      for name <- @shell_names,
          ClaudeCode.init("haiku", [], cwd: work, env: %{name => "v"}) !=
            {:error, {:invalid_option, :env}},
          do: name

    assert accepted == []
  end

  # A tool result that is not text breaks the contract: the provider
  # process crashes and writes its crash report, and the turn fails.
  test "a session with the map logs no key and no value of it, also at a provider crash",
       %{bin: bin} = ctx do
    turn(bin, 1, 1, begin() ++ [tool_use("toolu_01", %{}), tool_result("toolu_01", 17)])
    env = %{"HELYX_TEST_751" => @value}

    {:ok, session} =
      Helyx.Session.start(ctx.core,
        model: "claude-code/haiku",
        cwd: ctx.work,
        provider_opts: [env: env]
      )

    {:ok, _, _} = Helyx.Session.subscribe(session)
    {events, log} = ExUnit.CaptureLog.with_log(fn -> prompt(session, "go") end)
    assert [%{outcome: :error}] = for(%{type: :turn_end, data: data} <- events, do: data)
    assert log =~ "turn failed"
    shown? = Enum.any?([log, inspect(events)], &(&1 =~ @value or &1 =~ "HELYX_TEST_751"))
    refute shown?
  end

  test "the provider state shows no key and no value of the map", %{work: work} do
    text = inspect(harness(work, env: %{"HELYX_TEST_751" => @value}))
    shown? = text =~ @value or text =~ "HELYX_TEST_751"
    refute shown?
  end

  # The OS bounds argv and the environment together; 1,100,000 bytes is
  # over the 1,048,576 of macOS and the 131,072 of one Linux string.
  test "an env over the OS limit fails the turn with an error that holds no value",
       %{work: work} do
    state = harness(work, env: %{"HELYX_TEST_751" => String.duplicate("v", 1_100_000)})

    assert {_from, [{:reply, _, {:error, error}}], _state} =
             request(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("x")]}})

    assert error == {:not_started, "the perl watchdog gave no marker: "}
  end
end
