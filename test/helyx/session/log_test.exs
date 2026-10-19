defmodule Helyx.Session.LogTest do
  # The log of a session holds no message text (#756, #788,
  # docs/features/session-lifecycle.md, "Log and crash reports").
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Helyx.Test.Events
  import Helyx.Test.SessionCase

  alias Helyx.Message.ToolCall
  alias Helyx.Session

  setup :start_core

  @prompt "the prompt text of the user"
  @secret "the text of a stray message"

  # The plugins of the crash tests (#788). Each callback fails a BIF with a
  # text, so the message of the error and the arguments of its stack frame
  # hold the text.
  defmodule Crash do
    @moduledoc false
    def text, do: "the text of a plugin crash"
    def crash(text), do: :maps.get(text, %{})
  end

  defmodule CrashContext do
    @moduledoc false
    @behaviour Helyx.ModelContext

    @impl true
    def build(context, _opts), do: Crash.crash(Helyx.Message.text(List.last(context.messages)))
  end

  defmodule CrashMemory do
    @moduledoc false
    @behaviour Helyx.Memory

    @impl true
    def recall(query, _opts), do: Crash.crash(query.text)

    @impl true
    def sync(entries, _opts), do: Crash.crash(Helyx.Message.text(hd(entries).message))
  end

  # "text" crashes the run; "hold" holds a handle, and the release crashes.
  defmodule CrashTool do
    @moduledoc false
    use Helyx.Test.Tool, name: "crash", description: "Crashes with its text."

    @impl true
    def run(%{"text" => text}, _cwd), do: Crash.crash(text)

    def run(%{"hold" => true}, _cwd) do
      Helyx.Tool.hold(:handle)
      {:ok, "held"}
    end

    @impl true
    def release(_handles, _mode, _deadline), do: Crash.crash(Crash.text())
  end

  # The lines of one process: the tests that run at the same time also log.
  defp lines(log, pid) do
    pid = "pid=#{:erlang.pid_to_list(pid)}"
    log |> String.split("\n") |> Enum.filter(&(&1 =~ pid))
  end

  # Hands that send their results to the test process.
  defp start_hands(core, tools) do
    start_supervised!(
      {Session.Hands,
       core: core,
       cwd: File.cwd!(),
       background_dir: Path.join(System.tmp_dir!(), "helyx-log-#{System.unique_integer()}"),
       session: self(),
       tools: tools}
    )
  end

  # A crash of `pid` by `fun`, with the log of the whole node.
  defp crash_log(pid, fun) do
    ref = Process.monitor(pid)

    capture_log([metadata: [:pid]], fn ->
      fun.()
      assert_receive {:DOWN, ^ref, :process, _, _}, wait_ms()
    end)
  end

  test "a failed turn logs the kind of its reason, and the client gets its text", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/exception_error")
    {:ok, _, _} = Session.subscribe(session)

    {events, log} =
      with_log([metadata: [:pid]], fn ->
        :ok = Session.prompt(session, @prompt)
        collect_until(:turn_end)
      end)

    assert List.last(events).data.error == "rate limited"
    assert [line] = lines(log, Session.pid(session))
    assert line =~ "turn failed: RuntimeError"
    refute log =~ "rate limited"
    refute log =~ @prompt
  end

  test "the crash report of the session process holds no message text", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/ok")
    {:ok, _, _} = Session.subscribe(session)
    :ok = Session.prompt(session, @prompt)
    collect_until(:turn_end)
    pid = Session.pid(session)

    # No clause takes this message: the session crashes, with the message
    # and the state, which holds the prompt, in the arguments of the call.
    log = crash_log(pid, fn -> send(pid, {:stray, @secret}) end)

    assert [line] = lines(log, pid)
    assert line =~ "terminating"
    assert log =~ "Helyx.Session.Server.TurnLoop.handle/2"
    assert log =~ ~s{** (stop) ":function_clause"}
    refute log =~ @prompt
    refute log =~ @secret
  end

  test "the crash report of the hands holds no message text", %{core: core} do
    state = %Session.Hands.State{
      core: core,
      cwd: File.cwd!(),
      background_dir: Path.join(System.tmp_dir!(), "helyx-log-#{System.unique_integer()}"),
      session: self(),
      tools: %{}
    }

    {:ok, hands} = GenServer.start(Session.Hands, state)
    log = crash_log(hands, fn -> catch_exit(GenServer.call(hands, {:stray, @secret})) end)

    assert [line] = lines(log, hands)
    assert line =~ "terminating"
    assert log =~ ~s{** (stop) ":function_clause"}
    refute log =~ @secret
  end

  test "the crash report of the sync worker holds no message text" do
    {:ok, sync} = GenServer.start(Session.Sync, {Helyx.Test.Memory, [], self()})
    log = crash_log(sync, fn -> send(sync, {:stray, @secret}) end)

    assert [line] = lines(log, sync)
    assert line =~ "terminating"
    assert log =~ ~s{** (stop) ":function_clause"}
    refute log =~ @secret
  end

  describe "the crash of a process of plugin code" do
    test "a prepare Task logs its kind, and the client gets its text" do
      core = start_core([Helyx.Test.Provider, CrashContext])
      {:ok, session} = Session.start(core, model: "test/ok")
      {:ok, _, _} = Session.subscribe(session)

      {events, log} =
        with_log(fn ->
          :ok = Session.prompt(session, Crash.text())
          collect_until(:turn_end)
        end)

      assert List.last(events).data.error =~ Crash.text()
      assert log =~ "prepare task crashed: :badkey"
      refute log =~ Crash.text()
    end

    test "a recall call logs its kind", %{core: core} do
      opts = [core: core, recall_ms: wait_ms(), turn_id: "t1"]
      transcript = [Helyx.Message.user(Crash.text())]

      log =
        capture_log(fn ->
          assert Session.Recall.run(CrashMemory, transcript, opts, 2 * wait_ms()) ==
                   {:ok, :failed}
        end)

      assert log =~ "memory recall crashed: :badkey"
      refute log =~ Crash.text()
    end

    test "a sync call logs its kind", %{core: core} do
      {:ok, sync} = GenServer.start(Session.Sync, {CrashMemory, [core: core], self()})
      entries = [%{message: Helyx.Message.user(Crash.text()), persisted: true}]

      log =
        capture_log(fn ->
          :ok = Session.Sync.push(sync, :live, entries)
          assert_receive {:memory_notice, ^sync, _text}, wait_ms()
        end)

      assert log =~ "memory sync crashed: :badkey"
      refute log =~ Crash.text()
    end

    test "a tool call logs its kind, and the model gets its text", %{core: core} do
      hands = start_hands(core, %{"crash" => CrashTool})
      call = %ToolCall{id: "c1", name: "crash", arguments: %{"text" => Crash.text()}}

      log =
        capture_log(fn ->
          :ok = Session.Hands.run(hands, "t1", call, %{})
          assert_receive {:tool_result, "t1", "c1", {:error, text}}, wait_ms()
          assert text =~ Crash.text()
        end)

      assert log =~ "tool crash failed: :badkey"
      refute log =~ Crash.text()
    end

    test "a release logs its kind", %{core: core} do
      hands = start_hands(core, %{"crash" => CrashTool})
      call = %ToolCall{id: "c1", name: "crash", arguments: %{"hold" => true}}

      log =
        capture_log(fn ->
          :ok = Session.Hands.run(hands, "t1", call, %{})

          assert_receive {:tool_result, "t1", "c1",
                          {:error, "a resource of the call could not be released"}},
                         wait_ms()
        end)

      assert log =~ "tool release crashed: :badkey"
      refute log =~ Crash.text()
    end

    test "a provider process logs its kind, and the hands get its reason", %{core: core} do
      hands = start_hands(core, %{})

      log =
        capture_log(fn ->
          ref =
            Session.Hands.start_provider(hands, Crash, fn _tref -> Crash.crash(Crash.text()) end)

          assert_receive {:provider_start, ^ref, {:ok, pid}}
          assert_receive {:provider_down, ^pid, reason}, wait_ms()

          # The reason of a Task crash, with the count of the arguments of a frame.
          assert {:task_exit, {{:badkey, text}, [{:erlang, :map_get, 2, _} | _]}} = reason
          assert text == Crash.text()
        end)

      assert log =~ "provider process crashed: :badkey"
      refute log =~ Crash.text()
    end
  end
end
