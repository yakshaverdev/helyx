defmodule CodingAgent.PrintTest do
  # Not async: print mode swaps the handler of the VM's signal server, and
  # the CLI runs a server in this VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Helyx.Test.Events, only: [wait_until: 1]

  alias CodingAgent.{Attach, CLI, Print}
  alias Helyx.TUI.Wire.Connection

  @moduletag :tmp_dir

  # Print mode never puts the VM back: it ends with a halt. In the test VM
  # the halt only reports, so each test puts the signal handler, SIGHUP,
  # and the log back itself.
  setup %{tmp_dir: dir} do
    {:ok, log} = :logger.get_handler_config(:default)
    # The skills of the host are not part of a run's stderr.
    Application.put_env(:coding_agent, :home, dir)
    sessions = Path.join(dir, "sessions")
    Application.put_env(:coding_agent, :sessions_dir, sessions)

    on_exit(fn ->
      Application.delete_env(:coding_agent, :home)
      Application.delete_env(:coding_agent, :sessions_dir)

      if server = Process.whereis(CodingAgent.Serve),
        do: Task.Supervisor.terminate_child(CodingAgent.Servers, server)

      # A test runs print mode once or more, and the handler of each run
      # stays: the VM gets its one handler back, and the log.
      reset_signal_server()
      :ok = :os.set_signal(:sighup, :default)
      _ = :logger.remove_handler(:default)
      :ok = :logger.add_handler(:default, :logger_std_h, log)
    end)

    %{sessions: sessions}
  end

  defmodule Stop do
    @moduledoc false
    # Ends its one reply with the stop reason that the model names; neither
    # `Helyx.Provider.Fake` nor `Helyx.Test.Gated.Loop` ends with another
    # reason than `:end_turn` or `:tool_use`. The model "burst" sends 20,000
    # deltas of one byte, and "burst.<gate>" first stops at the gate.
    use Helyx.Provider.Loop

    @impl true
    def id, do: "stop"

    @impl true
    def stream("burst", _context, opts), do: {:ok, Helyx.Test.Burst.stream(20_000, opts)}

    def stream("burst." <> gate, _context, opts),
      do:
        {:ok,
         Stream.concat(
           Helyx.Test.Gate.stream([:gate], gate),
           Helyx.Test.Burst.stream(20_000, opts)
         )}

    # The two waves of the ack test: 10,000 deltas, the gate, 10,000 more.
    # A wave's stream ends with its `:done`, which the first wave must not
    # send, so the test takes its deltas only.
    def stream("waves." <> gate, _context, opts) do
      first = 10_000 |> Helyx.Test.Burst.stream(opts) |> Stream.take(10_000)

      {:ok,
       Stream.concat([
         first,
         Helyx.Test.Gate.stream([:gate], gate),
         Helyx.Test.Burst.stream(10_000, opts)
       ])}
    end

    def stream(reason, _context, _opts) do
      stop = String.to_existing_atom(reason)
      {:ok, [{:text_delta, "cut"}, {:done, %{stop_reason: stop, usage: nil}}]}
    end
  end

  defmodule Device do
    @moduledoc false
    # A group leader that stands for the `user` device of the VM, as probed on
    # OTP 28: getopts reports `stdin: true` for a terminal, and in latin1 mode
    # a latin1 read returns the raw bytes, at most the count asked. `input` is the
    # piped bytes, or nil for a terminal that must not be read. The output is
    # kept for `output/1`.
    def start(stdin?, input) do
      state = %{stdin: stdin?, input: input, encoding: :unicode, out: []}
      spawn_link(fn -> loop(state) end)
    end

    def output(device) do
      send(device, {:output, self()})

      receive do
        {:output, ^device, out} -> out
      end
    end

    defp loop(state) do
      receive do
        {:io_request, from, reply_as, request} ->
          {reply, state} = request(request, state)
          send(from, {:io_reply, reply_as, reply})
          loop(state)

        {:output, pid} ->
          send(pid, {:output, self(), IO.iodata_to_binary(Enum.reverse(state.out))})
          loop(state)
      end
    end

    defp request(:getopts, state),
      do: {[binary: true, encoding: state.encoding, stdin: state.stdin], state}

    defp request({:setopts, [encoding: encoding]}, state),
      do: {:ok, %{state | encoding: encoding}}

    defp request({:put_chars, :unicode, chars}, state),
      do: {:ok, %{state | out: [IO.chardata_to_string(chars) | state.out]}}

    defp request({:get_chars, _encoding, _prompt, _count}, %{input: nil} = state),
      do: {{:error, :read_from_tty}, state}

    defp request({:get_chars, _encoding, _prompt, _count}, %{encoding: :unicode} = state),
      do: {{:error, :read_in_unicode_mode}, state}

    defp request({:get_chars, _encoding, _prompt, _count}, %{input: ""} = state),
      do: {:eof, state}

    # A unicode read takes each byte as a latin1 character.
    defp request({:get_chars, encoding, _prompt, count}, %{input: input} = state) do
      {bytes, rest} = :erlang.split_binary(input, min(count, byte_size(input)))

      reply =
        if encoding == :latin1, do: bytes, else: :unicode.characters_to_binary(bytes, :latin1)

      {reply, %{state | input: rest}}
    end
  end

  @max Print.max_stdin_bytes()
  # The halt after a signal waits for the end of the session; the margin is
  # for a loaded machine.
  @load_ms 5_000

  # Runs `fun` with `input` piped on stdin, or with a terminal on stdin when
  # `input` is `:tty`, and returns its result, stdout, and stderr.
  defp io(input, fun) do
    device = if input == :tty, do: Device.start(true, nil), else: Device.start(false, input)

    old = Process.group_leader()

    stderr =
      capture_io(:stderr, fn ->
        Process.group_leader(self(), device)

        try do
          send(self(), {:result, fun.()})
        after
          Process.group_leader(self(), old)
        end
      end)

    assert_received {:result, result}
    {result, Device.output(device), stderr}
  end

  # A server of this VM with the providers of the tests: the CLI starts one
  # that a print run attaches to (docs/features/print-mode.md).
  defp server(dir) do
    core = :"print_core_#{System.unique_integer([:positive])}"
    plugins = [Stop, Helyx.Test.Gated.Loop | CodingAgent.plugins()]
    start_supervised!({Helyx.Core, name: core, plugins: plugins, sessions_dir: dir})
    transport = start_supervised!({Helyx.Transport.WebSocket, core: core, port: 0})
    %{core: core, port: Helyx.Transport.WebSocket.port(transport)}
  end

  # Print mode as the CLI runs it: the run process connects, which makes it
  # the owner of the events.
  defp print_run(server, opts, test \\ self()) do
    Print.main(
      fn ->
        {:ok, socket, ws} =
          Helyx.TUI.Wire.connect(
            {127, 0, 0, 1},
            server.port,
            fn -> "token" end,
            Helyx.Test.Events.wait_ms()
          )

        CodingAgent.print(socket, ws, opts)
      end,
      halt(test)
    )
  end

  defp signal_handlers, do: :gen_event.which_handlers(:erl_signal_server)

  # Every handler that a run left in the signal server goes, and the VM's
  # own handler comes back once.
  defp reset_signal_server do
    for _ <- Enum.filter(signal_handlers(), &(&1 == Print.Signal)),
        do: :gen_event.delete_handler(:erl_signal_server, Print.Signal, [])

    for _ <- Enum.filter(signal_handlers(), &(&1 == :erl_signal_handler)),
        do: :gen_event.delete_handler(:erl_signal_server, :erl_signal_handler, [])

    :ok = :gen_event.add_handler(:erl_signal_server, :erl_signal_handler, [])
  end

  # A halt that reports the status to `test` and returns it, so `main/2`
  # returns the status in the test VM.
  defp halt(test), do: &(send(test, {:halt, &1}) && &1)

  # After a signal, `main/2` waits for the halt of the stop, which here is
  # only a message: the test ends the wait.
  defp end_wait(task) do
    await_sleep(task)
    Task.shutdown(task, :brutal_kill)
  end

  defp await_sleep(task) do
    wait_until(fn ->
      Process.info(task.pid, :current_function) == {:current_function, {Process, :sleep, 1}}
    end)
  end

  # The run process of `main/2`, and the connection that it owns.
  defp run_process(task) do
    {:monitors, [process: run]} = Process.info(task.pid, :monitors)
    {:monitors, [process: conn]} = Process.info(run, :monitors)
    {run, conn}
  end

  # The sub id of the subscription that the run process holds.
  defp subscription(conn) do
    conn |> :sys.get_state() |> Map.fetch!(:subs) |> Map.fetch!(:subs) |> Map.keys() |> hd()
  end

  describe "the CLI" do
    test "-p prints the answer on stdout and the session id on stderr, and saves the session",
         %{tmp_dir: dir} do
      assert {0, "-x say this\n", "helyx: session " <> id} =
               io("", fn ->
                 CLI.main(["-p", "-x say this", "--model", "fake/echo", dir], halt(self()))
               end)

      assert_received {:halt, 0}
      assert Print.Signal in signal_handlers()
      assert Process.whereis(Helyx.Core) == nil
      assert Process.whereis(CodingAgent.Serve) == nil

      # The run is a normal session: --list shows it with its prompt.
      id = String.trim_trailing(id, "\n")

      assert [line] =
               capture_io(fn -> CLI.main(["--list", dir]) end) |> String.split("\n", trim: true)

      assert line =~ ~r/^#{id}  .*  fake\/echo  -x say this$/
    end

    # A print run that found no server started one for itself; that one
    # stops, and so does the session that the run opened.
    test "a print run stops the session it opened", %{tmp_dir: dir, sessions: sessions} do
      result =
        Attach.serve(sessions, "fake/echo", fn _found ->
          {status, out, stderr} =
            io("", fn ->
              CLI.main(["-p", "x say this", "--model", "fake/echo", dir], halt(self()))
            end)

          {status, out, stderr, Helyx.Sessions.list_live(Helyx.Core)}
        end)

      assert {0, "x say this\n", "helyx: session " <> _, []} = result
      assert_received {:halt, 0}
    end

    # A session that was live before the run belongs to the other client.
    test "a print run joins a session that another client has open, and leaves it live",
         %{tmp_dir: dir, sessions: sessions} do
      assert :ok =
               Attach.serve(sessions, "fake/echo", fn _found ->
                 {:ok, socket, ws} = Attach.connect(sessions)
                 {:ok, conn, ref} = Connection.open(socket, ws)
                 assert {:ok, id} = Connection.start(conn, cwd: dir, model: "fake/echo")
                 assert {:ok, _snapshot, _sub} = Connection.subscribe(conn, id)

                 assert {0, "two\n", "helyx: session " <> line} =
                          io("", fn ->
                            CLI.main(["-p", "two", "--session", id], halt(self()))
                          end)

                 assert String.trim_trailing(line, "\n") == id
                 assert {:ok, [%{id: ^id, status: :idle}]} = Connection.list_live(conn)

                 Process.exit(conn, :kill)
                 Process.demonitor(ref, [:flush])
                 :ok
               end)
    end

    test "piped stdin joins the prompt as a block", %{tmp_dir: dir} do
      assert {0, out, _} =
               io("line one\nline two", fn ->
                 CLI.main(["--print", "why", "--model", "fake/echo", dir], halt(self()))
               end)

      # The echo model sends the words back, so whitespace runs keep their place.
      assert out == "why\n\n<stdin>\nline one\nline two\n</stdin>\n"
    end

    test "a failed turn prints nothing on stdout and returns 1", %{tmp_dir: dir} do
      assert {1, "", stderr} =
               io("", fn ->
                 CLI.main(["-p", "x", "--model", "fake/unscripted", dir], halt(self()))
               end)

      # The log of Core goes to stderr too, so the line is not the last one.
      assert stderr =~ ~s(\nhelyx: the turn failed: {:no_script, "unscripted"}\n)
    end

    # The model of a start is a param of the wire, and the server refuses it
    # before Core starts a session.
    test "a model ref that the server refuses is one stderr line and 1", %{tmp_dir: dir} do
      line = "helyx: could not start the agent: the model ref is not valid; use provider/model\n"

      assert {1, "", ^line} =
               io("", fn -> CLI.main(["-p", "x", "--model", "not-a-ref", dir], halt(self())) end)

      assert_received {:halt, 1}
    end

    # A server needs perl, as the tools do (docs/features/tui-attach.md,
    # decision 12). With no data folder, the tool check gives the line; with
    # one, the lock test of the folder does. The value of PATH is not shown
    # on a failure.
    test "with no perl on PATH a server starts for no command, and one line names perl",
         %{tmp_dir: dir, sessions: s} do
      path = System.get_env("PATH")
      empty = Path.join(dir, "no-perl")
      File.mkdir_p!(empty)
      on_exit(fn -> System.put_env("PATH", path) end)
      System.put_env("PATH", empty)

      tool =
        "helyx: could not start the agent: the bash tool is not available: " <>
          "perl not found: the bash tool needs perl to watch its commands\n"

      assert {1, "", ^tool} =
               io("", fn ->
                 CLI.main(["-p", "x", "--model", "fake/echo", dir], halt(self()))
               end)

      refute File.exists?(s)

      File.mkdir_p!(s)
      File.chmod!(s, 0o700)

      lock =
        "helyx: could not test the lock of the data folder: perl is not on the PATH; " <>
          "Helyx needs it for its file locks\n"

      for argv <- [["-p", "x", "--model", "fake/echo", dir], ["--list", dir]] do
        assert {1, "", ^lock} = io("", fn -> CLI.main(argv, halt(self())) end)
      end

      assert Process.whereis(Helyx.Core) == nil
      assert Process.whereis(CodingAgent.Serve) == nil
    end

    test "input over the bound fails before anything starts", %{tmp_dir: dir, sessions: s} do
      line = "helyx: the piped input is over the #{@max}-byte limit\n"

      assert {1, "", ^line} =
               io(String.duplicate("a", @max + 1), fn ->
                 CLI.main(["-p", "x", dir], halt(self()))
               end)

      refute File.exists?(s)
      assert Process.whereis(Helyx.Core) == nil
    end

    test "-p with --session or --resume continues the session in its folder",
         %{tmp_dir: dir, sessions: s} do
      assert {0, "one\n", "helyx: session " <> line} =
               io("", fn -> CLI.main(["-p", "one", "--model", "fake/echo", dir], halt(self())) end)

      id = String.trim_trailing(line, "\n")
      # --session takes the folder of the header, not the current one.
      assert {0, "two\n", stderr} =
               io("", fn -> CLI.main(["-p", "two", "--session", id], halt(self())) end)

      assert stderr == "helyx: session #{id}\n"

      three = "three\n\n<stdin>\npiped\n</stdin>"

      assert {0, ^three <> "\n", ^stderr} =
               io("piped", fn -> CLI.main(["-p", "three", "--resume", dir], halt(self())) end)

      assert {:ok, resumed} = Helyx.Test.SessionFile.resume(s, dir, id: id)

      assert Enum.map(resumed.messages, &{&1.role, Helyx.Message.text(&1)}) ==
               for(text <- ["one", "two", three], role <- [:user, :assistant], do: {role, text})

      assert Process.whereis(Helyx.Core) == nil
    end

    test "a resume that fails is one stderr line and 1, inside print mode", %{tmp_dir: dir} do
      missing = Helyx.Session.Id.new()

      for {argv, line} <- [
            {["--session", missing], ~s(helyx: no session "#{missing}"\n)},
            {["--resume", dir],
             "helyx: could not start the agent: no saved session for this directory; " <>
               "start one without --resume\n"}
          ] do
        assert {1, "", ^line} = io("", fn -> CLI.main(["-p", "x" | argv], halt(self())) end)
        assert_received {:halt, 1}
      end
    end

    test "--resume skips a file whose name is not a session id", %{tmp_dir: dir, sessions: s} do
      assert {0, _, _} =
               io("", fn -> CLI.main(["-p", "one", "--model", "fake/echo", dir], halt(self())) end)

      [path] = Path.wildcard(Path.join([s, "*", "*.jsonl"]))
      File.rename!(path, Path.join(Path.dirname(path), "a\e[2J\nb.jsonl"))

      assert {1, "", "helyx: could not start the agent: no saved session for this directory" <> _} =
               io("", fn -> CLI.main(["-p", "two", "--resume", dir], halt(self())) end)

      assert_received {:halt, 1}
    end

    test "-p does not combine with the list, and a resume keeps its model and folder" do
      for {argv, text} <- [
            {["-p", "x", "--list"], "--print does not combine with --list"},
            {["-p", "x", "--resume", "--model", "fake/echo"],
             "--model does not combine with --resume; a resumed session keeps its saved model"},
            {["-p", "x", "--session", "abc", "--model", "fake/echo"],
             "--model does not combine with --session"},
            {["-p", "x", "--session", "abc", "/tmp"],
             "a directory argument does not combine with --session"},
            {["-p", "x", "--session", "abc", "--resume"],
             "--resume does not combine with --session"}
          ] do
        assert {1, "", "helyx: " <> line} = io("", fn -> CLI.main(argv) end)
        assert line =~ text
      end

      assert {1, "", stderr} = io("", fn -> CLI.main(["-p"]) end)
      assert stderr =~ ~s("-p"; the options)
    end
  end

  describe "prompt/1" do
    test "reads no stdin when stdin is a terminal" do
      assert io(:tty, fn -> Print.prompt("q") end) == {{:ok, "q"}, "", ""}
    end

    test "empty input adds no block" do
      assert {{:ok, "q"}, "", ""} = io("", fn -> Print.prompt("q") end)
    end

    test "the bound of the input, in bytes" do
      at = String.duplicate("é", div(@max, 2))
      assert {{:ok, prompt}, _, _} = io(at, fn -> Print.prompt("q") end)
      assert prompt == "q\n\n<stdin>\n" <> at <> "\n</stdin>"

      assert {{:ok, _}, _, _} = io(String.duplicate("a", @max - 1), fn -> Print.prompt("q") end)

      over = "the piped input is over the #{@max}-byte limit"

      for input <- [String.duplicate("a", @max + 1), at <> "a", "a" <> at] do
        assert {{:error, ^over}, _, _} = io(input, fn -> Print.prompt("q") end)
      end

      assert {{:error, "the piped input is not UTF-8"}, _, _} =
               io(<<"ok", 0xFF>>, fn -> Print.prompt("q") end)
    end
  end

  describe "run/5" do
    test "an answer cut at the token limit is printed and returns 1", %{tmp_dir: dir} do
      server = server(dir)

      assert {1, "cut\n", stderr} =
               io("", fn ->
                 print_run(server, prompt: "q", cwd: dir, model: "stop/max_tokens")
               end)

      assert stderr =~ ~r/\Ahelyx: session \S+\nhelyx: the answer stopped at the token limit\n\z/
    end

    # Past 16,384 unacked events the server ends a subscription. Over the
    # wire an ack travels back from the client, so one burst of 20,000 can
    # pass that bound before the first ack arrives. The provider sends two
    # waves of 10,000 instead, and the test opens the gate only when the
    # server has the ack of the first (docs/features/replay-ring.md,
    # "Subscriptions").
    test "print mode acks: two waves of 10,000 deltas print the whole answer",
         %{tmp_dir: dir} do
      server = server(dir)
      test = self()
      gate = Helyx.Test.Gate.open()

      {:ok, session} =
        Helyx.Session.start(server.core,
          model: "stop/waves." <> gate,
          sessions_dir: dir,
          cwd: dir
        )

      assert {0, out, _stderr} =
               io("", fn ->
                 task =
                   Task.async(fn ->
                     print_run(server, [prompt: "q", cwd: dir, resume: session.id], test)
                   end)

                 assert_receive {:waiting, model}
                 await_ack(session)
                 send(model, :go)
                 Task.await(task, :infinity)
               end)

      assert out == String.duplicate("x", 20_000) <> "\n"
    end

    # The ack of the last multiple of 1,024 of the first wave: the print
    # client acks only each 1,024th seq (Helyx.Session.ack/2), so the ack of
    # the last event itself is no signal. The provider waits at the gate, so
    # no event follows it, and the session has emitted it when its mailbox
    # is empty.
    defp await_ack(session) do
      pid = Helyx.Session.pid(session)
      wait_until(fn -> elem(Process.info(pid, :message_queue_len), 1) == 0 end)
      last = :sys.get_state(pid).ring.seq
      target = last - rem(last, 1_024)
      wait_until(fn -> acked(pid) >= target end)
    end

    # The acked seq of the subscription of the session
    # (Helyx.Session.Server.Events.ack/3).
    defp acked(pid) do
      pid
      |> :sys.get_state()
      |> Map.fetch!(:subscribers)
      |> Map.values()
      |> Enum.map(fn {_monitor, _ref, acked, _answers?} -> acked end)
      |> Enum.max(fn -> 0 end)
    end

    # The run process is suspended during the burst, so it acks nothing: the
    # session ends its subscription as slow, and the server closes with 4408
    # (docs/features/tui-attach.md, decision 11).
    test "a print run that acks nothing gets the close of a slow client", %{tmp_dir: dir} do
      server = server(dir)
      test = self()
      gate = Helyx.Test.Gate.open()

      assert {1, "", stderr} =
               io("", fn ->
                 task =
                   Task.async(fn ->
                     print_run(
                       server,
                       [prompt: "q", cwd: dir, model: "stop/burst." <> gate],
                       test
                     )
                   end)

                 assert_receive {:waiting, model}
                 {run, conn} = run_process(task)
                 true = :erlang.suspend_process(run)
                 send(model, :go)
                 wait_until(fn -> not Process.alive?(conn) end)
                 true = :erlang.resume_process(run)
                 Task.await(task, :infinity)
               end)

      assert stderr =~ ~r/\nhelyx: the server closed a slow connection\n\z/
    end

    test "a refused answer is printed with a notice and returns 0", %{tmp_dir: dir} do
      server = server(dir)

      assert {0, "cut\n", stderr} =
               io("", fn -> print_run(server, prompt: "q", cwd: dir, model: "stop/refused") end)

      assert stderr =~ "helyx: the answer stopped: the provider refused or filtered it\n"
    end

    # #606: the notice of a loss before the subscribe reached no client.
    test "a session that stopped saving before the run writes the not-saved notice on stderr",
         %{tmp_dir: dir} do
      server = server(dir)

      {:ok, session} =
        Helyx.Session.start(server.core, model: "fake/echo", sessions_dir: dir, cwd: dir)

      Helyx.Test.UnsavedSession.stop_saving(session)

      assert {0, "q\n", stderr} =
               io("", fn -> print_run(server, prompt: "q", cwd: dir, resume: session.id) end)

      assert stderr =~
               ~r/\Ahelyx: session \S+\nhelyx: new messages of this session are not saved\n\z/
    end

    test "main/2 sends the log to stderr, and an error to one stderr line with 1" do
      {:ok, before} = :logger.get_handler_config(:default)
      test = self()

      assert {1, "", "helyx: no\n"} =
               io("", fn ->
                 Print.main(
                   fn ->
                     send(test, {:log, :logger.get_handler_config(:default)})
                     {:error, "no"}
                   end,
                   halt(test)
                 )
               end)

      assert_received {:log, {:ok, log}}
      assert log == put_in(before.config.type, :standard_error)
      assert_received {:halt, 1}
    end

    test "a throw or an exit of the run gives one stderr line and 1" do
      for {fun, line} <- [
            {fn -> throw(:t) end, "helyx: ** (throw) :t\n"},
            {fn -> exit(:x) end, "helyx: ** (exit) :x\n"}
          ] do
        assert {1, "", ^line} = io("", fn -> Print.main(fun, halt(self())) end)
        assert_received {:halt, 1}
      end
    end

    test "SIGTERM during the turn ends the session, then halts with 143", %{tmp_dir: dir} do
      server = server(dir)
      gate = Helyx.Test.Gate.open()
      test = self()

      {:ok, session} =
        Helyx.Session.start(server.core, model: "gated/" <> gate, sessions_dir: dir, cwd: dir)

      assert {:ok, _, stderr} =
               io("", fn ->
                 task =
                   Task.async(fn ->
                     print_run(server, [prompt: "fail", cwd: dir, resume: session.id], test)
                   end)

                 assert_receive {:waiting, _}
                 :gen_event.notify(:erl_signal_server, :sigterm)
                 assert_receive {:halt, 143}

                 # The run has ended and waits for the halt: the handler
                 # stays, and a second signal is ignored.
                 await_sleep(task)
                 :gen_event.sync_notify(:erl_signal_server, :sighup)
                 assert Print.Signal in signal_handlers()
                 end_wait(task)
                 :ok
               end)

      assert stderr =~ ~r/\nhelyx: (the turn was aborted|the session stopped)\n/
      refute_received {:halt, _}
    end

    test "SIGHUP halts with 129, and the first signal sets the status" do
      test = self()

      task =
        Task.async(fn ->
          Print.main(
            fn ->
              :gen_event.sync_notify(:erl_signal_server, :sighup)
              :gen_event.sync_notify(:erl_signal_server, :sigterm)
              0
            end,
            halt(test)
          )
        end)

      assert_receive {:halt, 129}
      end_wait(task)
      refute_received {:halt, _}
    end

    @tag :slow
    test "the wait for the end of the session is bounded", %{tmp_dir: dir} do
      server = server(dir)
      gate = Helyx.Test.Gate.open()
      test = self()

      {:ok, session} =
        Helyx.Session.start(server.core, model: "gated/" <> gate, sessions_dir: dir, cwd: dir)

      io("", fn ->
        task =
          Task.async(fn ->
            print_run(server, [prompt: "fail", cwd: dir, resume: session.id], test)
          end)

        assert_receive {:waiting, gate_pid}
        # A session that does not answer the stop request.
        pid = Helyx.Session.pid(session)
        :erlang.suspend_process(pid)
        started = System.monotonic_time(:millisecond)
        :gen_event.notify(:erl_signal_server, :sigterm)
        assert_receive {:halt, 143}, Print.abort_ms() + @load_ms
        assert System.monotonic_time(:millisecond) - started >= Print.abort_ms()

        :erlang.resume_process(pid)
        send(gate_pid, :go)
        end_wait(task)
      end)
    end

    test "an aborted turn prints nothing on stdout and returns 1", %{tmp_dir: dir} do
      server = server(dir)
      test = self()
      gate = Helyx.Test.Gate.open()

      {:ok, session} =
        Helyx.Session.start(server.core, model: "gated/" <> gate, sessions_dir: dir, cwd: dir)

      assert {1, "", stderr} =
               io("", fn ->
                 task =
                   Task.async(fn ->
                     print_run(server, [prompt: "fail", cwd: dir, resume: session.id], test)
                   end)

                 assert_receive {:waiting, _}
                 :ok = Helyx.Session.abort(session)
                 Task.await(task, :infinity)
               end)

      assert stderr =~ ~r/\nhelyx: the turn was aborted\n\z/
    end

    test "a notice goes to stderr as one line of at most 4000 bytes", %{tmp_dir: dir} do
      server = server(dir)
      test = self()
      gate = Helyx.Test.Gate.open()

      {:ok, session} =
        Helyx.Session.start(server.core, model: "gated/" <> gate, sessions_dir: dir, cwd: dir)

      notice = %Helyx.Event{
        type: :notice,
        session_id: session.id,
        instance_id: nil,
        turn_id: nil,
        seq: 0,
        data: %{text: String.duplicate("n", 10_000) <> "\nnext"}
      }

      assert {1, "", stderr} =
               io("", fn ->
                 task =
                   Task.async(fn ->
                     print_run(server, [prompt: "fail", cwd: dir, resume: session.id], test)
                   end)

                 assert_receive {:waiting, gate_pid}
                 {run, conn} = run_process(task)
                 send(run, {:helyx_event, subscription(conn), notice})
                 send(gate_pid, :go)
                 Task.await(task, :infinity)
               end)

      # The log line of the failed turn comes from another process, in any order.
      lines = String.split(stderr, "\n", trim: true)
      assert ["helyx: " <> line] = Enum.filter(lines, &String.starts_with?(&1, "helyx: nn"))
      assert byte_size(line) <= 4000
      refute "next" in lines
    end

    # #591: a session on the model "fake/bg" whose first turn starts a
    # background bash run that ends once the file `gate` in `dir` exists,
    # and answers "started"; the turns after it answer `answers`. With
    # `foreground: true` the first turn also runs a foreground bash call that
    # ends once the file `foreground` in `dir` exists.
    defp bg_session(server, dir, answers, opts \\ []) do
      {foreground, opts} = Keyword.pop(opts, :foreground, false)
      gate = Path.join(dir, "gate")
      call = bash_call("c1", gate, true)

      calls =
        if foreground,
          do: [call, bash_call("c2", Path.join(dir, "foreground"), false)],
          else: [call]

      :ok = Helyx.Provider.Fake.script(server.core, "bg", [calls, ["started"] | answers])

      {:ok, session} =
        Helyx.Session.start(
          server.core,
          [model: "fake/bg", cwd: dir] ++ Keyword.put_new(opts, :sessions_dir, dir)
        )

      {:ok, _, _} = Helyx.Session.subscribe(session)
      %{session: session, gate: gate}
    end

    defp bash_call(id, file, background) do
      command = "until [ -e '#{file}' ]; do sleep 0.2; done"
      args = %{"command" => command, "background" => background}
      %Helyx.Message.ToolCall{id: id, name: "bash", arguments: args}
    end

    defp turn_end do
      assert_receive {:helyx_event, %Helyx.Event{type: :turn_end, data: data}}
      data
    end

    test "print mode waits for a background run; its end opens the last turn", %{tmp_dir: dir} do
      server = server(dir)
      %{session: session, gate: gate} = bg_session(server, dir, [["finished"]])
      test = self()

      # Had print mode ended at the first turn, stdout would hold "started".
      assert {0, "finished\n", stderr} =
               io("", fn ->
                 task =
                   Task.async(fn ->
                     print_run(server, [prompt: "q", cwd: dir, resume: session.id], test)
                   end)

                 assert turn_end() == %{outcome: :done}
                 File.write!(gate, "")
                 assert turn_end() == %{outcome: :done}
                 Task.await(task, :infinity)
               end)

      assert stderr =~ ~r/\Ahelyx: session \S+\nhelyx: waiting for background runs: 1\n\z/
    end

    @held_line "\nhelyx: background runs whose end did not reach the agent: 1\n"

    test "an end held between turns ends print mode with the last answer, one line, and 1",
         %{tmp_dir: dir} do
      server = server(dir)
      %{session: session, gate: gate} = bg_session(server, dir, [])
      test = self()

      assert {1, "started\n", stderr} =
               io("", fn ->
                 task =
                   Task.async(fn ->
                     print_run(server, [prompt: "q", cwd: dir, resume: session.id], test)
                   end)

                 assert turn_end() == %{outcome: :done}
                 # The abort of the idle session sets the hold of the ends.
                 :ok = Helyx.Session.abort(session)
                 File.write!(gate, "")
                 Task.await(task, :infinity)
               end)

      assert stderr =~ @held_line
    end

    # No Fake turn gives an end back held, so the test sends the count that
    # the session would send.
    test "a normal turn end with a held end gives the answer and 1", %{tmp_dir: dir} do
      server = server(dir)
      %{session: session} = bg_session(server, dir, [], foreground: true)
      test = self()

      hold = %Helyx.Event{
        type: :queue_update,
        session_id: session.id,
        instance_id: nil,
        turn_id: nil,
        seq: 0,
        data: %{steers: 0, follow_ups: 0, running: 0, held: 1, waiting: 0}
      }

      assert {1, "started\n", stderr} =
               io("", fn ->
                 task =
                   Task.async(fn ->
                     print_run(server, [prompt: "q", cwd: dir, resume: session.id], test)
                   end)

                 assert_receive {:helyx_event, %Helyx.Event{type: :tool_execution_end}}
                 {run, conn} = run_process(task)
                 send(run, {:helyx_event, subscription(conn), hold})
                 File.write!(Path.join(dir, "foreground"), "")
                 assert turn_end() == %{outcome: :done}
                 Task.await(task, :infinity)
               end)

      assert stderr =~ @held_line
    end

    defp one_call_session(server, dir, args) do
      call = %Helyx.Message.ToolCall{id: "c1", name: "bash", arguments: args}
      :ok = Helyx.Provider.Fake.script(server.core, "one", [[call], ["answered"]])

      {:ok, session} =
        Helyx.Session.start(server.core, model: "fake/one", cwd: dir, sessions_dir: dir)

      session
    end

    # The session counts the runs (`Helyx.Session.Queue`); print mode reads
    # no result text.
    test "a foreground result that opens with the start line opens no run", %{tmp_dir: dir} do
      server = server(dir)
      line = ~s(<background id="abcdefghijkl" status="started">\\nfixture\\n)
      session = one_call_session(server, dir, %{"command" => "printf '#{line}'"})

      assert {0, "answered\n", stderr} =
               io("", fn ->
                 print_run(server, prompt: "q", cwd: dir, resume: session.id)
               end)

      assert stderr =~ ~r/\Ahelyx: session \S+\n\z/
    end

    test "a background call whose result is an error opens no run", %{tmp_dir: dir} do
      server = server(dir)
      args = %{"command" => "true", "background" => true, "timeout" => 0}
      session = one_call_session(server, dir, args)

      assert {0, "answered\n", stderr} =
               io("", fn ->
                 print_run(server, prompt: "q", cwd: dir, resume: session.id)
               end)

      assert stderr =~ ~r/\Ahelyx: session \S+\n\z/
    end

    test "a resumed session closes its lost runs in the prompt turn", %{tmp_dir: dir} do
      server = server(dir)
      %{session: one} = bg_session(server, dir, [["resumed"]])

      :ok = Helyx.Session.prompt(one, "q")
      assert turn_end() == %{outcome: :done}
      Helyx.Test.SessionFile.stop(one)

      assert {0, "resumed\n", _stderr} =
               io("", fn -> print_run(server, prompt: "again", cwd: dir, resume: true) end)
    end

    for {signal, status} <- [sigterm: 143, sighup: 129] do
      test "#{signal} during the wait for a background run halts with #{status}",
           %{tmp_dir: dir} do
        server = server(dir)
        %{session: session} = bg_session(server, dir, [])
        test = self()

        io("", fn ->
          task =
            Task.async(fn ->
              print_run(server, [prompt: "q", cwd: dir, resume: session.id], test)
            end)

          assert turn_end() == %{outcome: :done}
          {run, _conn} = run_process(task)
          :gen_event.notify(:erl_signal_server, unquote(signal))
          assert_receive {:halt, unquote(status)}
          # In the VM the halt ends the run process, which still waits.
          Process.exit(run, :kill)
          end_wait(task)
        end)

        refute_received {:halt, _}
      end
    end

    test "a session that stops while the turn runs returns 1", %{tmp_dir: dir} do
      server = server(dir)
      test = self()
      gate = Helyx.Test.Gate.open()

      {:ok, session} =
        Helyx.Session.start(server.core, model: "gated/" <> gate, sessions_dir: dir, cwd: dir)

      assert {1, "", stderr} =
               io("", fn ->
                 task =
                   Task.async(fn ->
                     print_run(server, [prompt: "fail", cwd: dir, resume: session.id], test)
                   end)

                 assert_receive {:waiting, _}
                 GenServer.stop(Helyx.Session.pid(session))
                 Task.await(task, :infinity)
               end)

      assert stderr =~ ~r/\nhelyx: the session stopped\n\z/
    end
  end

  test "a skill command expands after the scan notices go to stderr", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, ".git"))

    for {name, frontmatter} <- [
          {"probe-skill-471", "name: probe-skill-471\ndescription: Probe.\n"},
          {"probe-bad-471", "name: other\ndescription: Probe.\n"}
        ] do
      File.mkdir_p!(Path.join(dir, ".agents/skills/#{name}"))

      File.write!(
        Path.join(dir, ".agents/skills/#{name}/SKILL.md"),
        "---\n#{frontmatter}---\nDo it.\n"
      )
    end

    stderr =
      capture_io(:stderr, fn ->
        send(self(), {:prompt, Print.skills("/probe-skill-471 730", dir)})
        send(self(), {:plain, Print.skills("/probe-none 730", dir)})
      end)

    bad = Path.join(dir, ".agents/skills/probe-bad-471")
    assert stderr =~ "helyx: skill #{bad} is not loaded: the name other is not the folder name\n"
    assert_received {:prompt, prompt}
    assert prompt =~ ~r/\A<skill name="probe-skill-471">\n.*Do it\.\n\n<\/skill>\n\n730\z/s
    assert_received {:plain, "/probe-none 730"}
  end
end
