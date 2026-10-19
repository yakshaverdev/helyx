defmodule Helyx.Provider.Codex.EnvTest do
  # The `env` option (docs/features/harness-no-state.md, "The environment
  # of the program"). No test prints a value: the fake compares them and
  # writes words.
  use ExUnit.Case, async: true

  import Helyx.Test.CodexFake
  import Helyx.Test.HarnessDriver

  alias Helyx.Message
  alias Helyx.Provider.Codex

  @moduletag :tmp_dir
  setup {Helyx.Test.CodexFake, :setup_fake}

  @value "a b=c é"

  # Run `n` answers `initialize`, then writes `env.n` as the Claude Code
  # test does.
  defp check(bin, n, home) do
    on(
      bin,
      n,
      "initialize",
      [j(%{id: "@", result: %{userAgent: "fake", platformOs: "macos"}})],
      """
      { [ "$HELYX_TEST_751" = '#{@value}' ] && echo map; [ "$HOME" = '#{home}' ] && echo home
        [ "$CODEX_HOME" = '#{home}' ] && echo folder
        case "$PATH" in *test_dispatch*) echo inherited ;; esac; } > "$d/env.#{n}"
      """
    )
  end

  defp seen(bin, n), do: bin |> Path.join("env.#{n}") |> File.read!() |> String.split()

  defp run(state, system, text) do
    context = %Helyx.Context{system: system, messages: [Message.user(text)]}
    {_from, actions, state} = ask(state, {:turn, "t1", context})
    {_actions, state} = pump(Codex, state, actions, &turn_ended?/1)
    state
  end

  test "every launch gets the map on top of the inherited environment",
       %{bin: bin, work: work} do
    fresh(bin, 1, tid(), reply(tid(), "one"))
    on(bin, 2, "thread/resume", [j(%{id: "@", result: %{thread: thread(tid())}})])
    on(bin, 2, "turn/start", turn(tid(), reply(tid(), "two")))
    for n <- [1, 2], do: check(bin, n, work)

    env = %{"HELYX_TEST_751" => @value, "HOME" => work, "CODEX_HOME" => work}
    {:ok, state} = connect(work, env: env)
    # A prompt change: a new program resumes the thread.
    state = run(run(state, "A", "x"), "B", "y")
    close(state)

    assert runs(bin) == "2"
    assert seen(bin, 1) == ["map", "home", "folder", "inherited"]
    assert seen(bin, 2) == ["map", "home", "folder", "inherited"]
  end

  test "a name that is not a shell identifier or a value that is empty, not UTF-8, or has a NUL fails the init with the option only",
       %{work: work} do
    bad = [
      nil,
      %{"A-B" => "v"},
      %{"PWD" => "v"},
      %{"A" => ""},
      %{"A" => "v\0w"},
      %{"A" => <<0xFF>>}
    ]

    for bad <- bad do
      assert connect(work, env: bad) == {:error, {:invalid_option, :env}}
    end
  end

  test "the provider state shows no key and no value of the map", %{bin: bin, work: work} do
    initialize(bin, 1)
    {:ok, state} = connect(work, env: %{"HELYX_TEST_751" => @value})
    text = inspect(state)
    close(state)
    shown? = text =~ @value or text =~ "HELYX_TEST_751"
    refute shown?
  end

  # As in the Claude Code test: perl stops before the marker, and its
  # error lists the folders of PERL5LIB.
  test "a connect that perl fails gives the values of the map masked", %{work: work} do
    env = %{"PERL5LIB" => "/tmp/HELYX_751_PRIVATE_CANARY", "PERL5OPT" => "-MHelyx751Missing"}
    assert {:error, {:not_started, text}} = connect(work, env: env)
    masked? = text =~ "<env>"
    leaked? = text =~ "HELYX_751_PRIVATE_CANARY" or text =~ "-MHelyx751Missing"
    assert masked?
    refute leaked?
  end

  # As in the Claude Code test.
  test "an env over the OS limit fails the connect with an error that holds no value",
       %{work: work} do
    assert connect(work, env: %{"HELYX_TEST_751" => String.duplicate("v", 1_100_000)}) ==
             {:error, {:not_started, "the perl watchdog gave no marker: "}}
  end
end
