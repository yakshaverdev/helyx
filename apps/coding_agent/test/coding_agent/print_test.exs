defmodule CodingAgent.PrintTest do
  # Not async: print mode swaps the handler of the VM's signal server, and
  # the CLI runs Core under its default name.
  use ExUnit.Case, async: false

  # Print mode never puts the VM back: it ends with a halt. In the test VM
  # the halt only reports, so each test puts the signal handler, SIGHUP,
  # and the log back itself.
  setup do
    {:ok, log} = :logger.get_handler_config(:default)

    on_exit(fn ->
      if Print.Signal in :gen_event.which_handlers(:erl_signal_server) do
        :ok =
          :gen_event.swap_handler(
            :erl_signal_server,
            {Print.Signal, []},
            {:erl_signal_handler, []}
          )

        :ok = :os.set_signal(:sighup, :default)
        :ok = :logger.remove_handler(:default)
        :ok = :logger.add_handler(:default, :logger_std_h, log)
      end
    end)
  end

  defmodule Stop do
    @moduledoc false
    # Ends its one reply with the stop reason that the model names; neither
    # `Helyx.Provider.Fake` nor `Helyx.Test.Gated.Loop` ends with another
    # reason than `:end_turn` or `:tool_use`.
    use Helyx.Provider.Loop

    @impl true
    def id, do: "stop"

    @impl true
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

  import ExUnit.CaptureIO
  import Helyx.Test.Events, only: [wait_until: 1]

  alias CodingAgent.{CLI, Print}

  @max Print.max_stdin_bytes()
  # The halt after a signal waits for the abort; the margin is for a loaded machine.
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

  defp start_core do
    core = :"print_core_#{System.unique_integer([:positive])}"
    plugins = [Stop, Helyx.Test.Gated.Loop | CodingAgent.plugins()]
    start_supervised!({Helyx.Core, name: core, plugins: plugins})
    core
  end

  defp signal_handlers, do: :gen_event.which_handlers(:erl_signal_server)

  # A halt that reports the status to `test` and returns it, so `main/2`
  # returns the status in the test VM.
  defp halt(test), do: &(send(test, {:halt, &1}) && &1)

  # `run/2` inside print mode.
  defp run(session, prompt, test \\ self()) do
    Print.main(fn -> Print.run(session, prompt) end, halt(test))
  end

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

  describe "the CLI" do
    @describetag :tmp_dir

    setup %{tmp_dir: dir} do
      sessions = Path.join(dir, "sessions")
      Application.put_env(:coding_agent, :sessions_dir, sessions)
      on_exit(fn -> Application.delete_env(:coding_agent, :sessions_dir) end)
      %{sessions: sessions}
    end

    test "-p prints the answer on stdout and the session id on stderr, and saves the session",
         %{tmp_dir: dir} do
      assert {0, "-x say this\n", "helyx: session " <> id} =
               io("", fn ->
                 CLI.main(["-p", "-x say this", "--model", "fake/echo", dir], halt(self()))
               end)

      assert_received {:halt, 0}
      assert Print.Signal in signal_handlers()
      assert Process.whereis(Helyx.Core) == nil

      # The run is a normal session: --list shows it with its prompt.
      id = String.trim_trailing(id, "\n")

      assert [line] =
               capture_io(fn -> CLI.main(["--list", dir]) end) |> String.split("\n", trim: true)

      assert line =~ ~r/^#{id}  .*  fake\/echo  -x say this$/
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

    # #579: the lock take of another process holds the session.
    test "a session open in another process is one line and 1, with -p and without", %{
      tmp_dir: dir,
      sessions: s
    } do
      assert {0, _, "helyx: session " <> line} =
               io("", fn -> CLI.main(["-p", "one", "--model", "fake/echo", dir], halt(self())) end)

      id = String.trim_trailing(line, "\n")
      [path] = Path.wildcard(Path.join([s, "*", id <> ".jsonl"]))
      {:ok, lock, nil} = Helyx.Session.Lock.hold(path, fn -> {:ok, nil} end)
      expected = "helyx: session #{id} is open in another process\n"

      for argv <- [["--session", id], ["--resume", dir]] do
        assert {1, "", ^expected} =
                 io("", fn -> CLI.main(["-p", "two" | argv], halt(self())) end)

        assert_received {:halt, 1}
      end

      assert {1, "", ^expected} = io("", fn -> CLI.main(["--session", id]) end)
      Helyx.Session.Lock.release(lock)
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

  describe "run/2" do
    @tag :tmp_dir
    test "an answer cut at the token limit is printed and returns 1", %{tmp_dir: dir} do
      {:ok, session} =
        Helyx.Session.start(start_core(), model: "stop/max_tokens", sessions_dir: dir, cwd: dir)

      assert {1, "cut\n", stderr} = io("", fn -> run(session, "q") end)
      assert stderr =~ ~r/\Ahelyx: session \S+\nhelyx: the answer stopped at the token limit\n\z/
    end

    test "a refused answer is printed with a notice and returns 0" do
      {:ok, session} = Helyx.Session.start(start_core(), model: "stop/refused")

      assert {0, "cut\n", stderr} = io("", fn -> run(session, "q") end)
      assert stderr =~ "helyx: the answer stopped: the provider refused or filtered it\n"
    end

    # #606: the notice of a loss before the subscribe reached no client.
    @tag :tmp_dir
    test "a session that lost its lock before the run writes the not-saved notice on stderr", %{
      tmp_dir: dir
    } do
      {:ok, session} =
        Helyx.Session.start(start_core(), model: "fake/echo", sessions_dir: dir, cwd: dir)

      Helyx.Test.LostLock.kill(session)

      assert {0, "q\n", stderr} = io("", fn -> run(session, "q") end)

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

    test "SIGTERM during the turn aborts it, then halts with 143" do
      gate = Helyx.Test.Gate.open()
      {:ok, session} = Helyx.Session.start(start_core(), model: "gated/" <> gate)
      test = self()

      assert {:ok, _, stderr} =
               io("", fn ->
                 task = Task.async(fn -> run(session, "fail", test) end)
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

      assert stderr =~ "\nhelyx: the turn was aborted\n"
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
    test "the wait for the abort is bounded" do
      gate = Helyx.Test.Gate.open()
      {:ok, session} = Helyx.Session.start(start_core(), model: "gated/" <> gate)
      test = self()

      io("", fn ->
        task = Task.async(fn -> run(session, "fail", test) end)
        assert_receive {:waiting, gate_pid}
        # A session that does not answer the abort.
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

    test "an aborted turn prints nothing on stdout and returns 1" do
      test = self()
      gate = Helyx.Test.Gate.open()
      {:ok, session} = Helyx.Session.start(start_core(), model: "gated/" <> gate)

      assert {1, "", stderr} =
               io("", fn ->
                 task = Task.async(fn -> run(session, "fail", test) end)
                 assert_receive {:waiting, _}
                 :ok = Helyx.Session.abort(session)
                 Task.await(task, :infinity)
               end)

      assert stderr =~ ~r/\nhelyx: the turn was aborted\n\z/
    end

    test "a notice goes to stderr as one line of at most 4000 bytes" do
      test = self()
      gate = Helyx.Test.Gate.open()
      {:ok, session} = Helyx.Session.start(start_core(), model: "gated/" <> gate)

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
                 task = Task.async(fn -> run(session, "fail", test) end)
                 assert_receive {:waiting, gate_pid}
                 # The run, which subscribed, is the process that `main/2` monitors.
                 {:monitors, [process: run_pid]} = Process.info(task.pid, :monitors)
                 send(run_pid, {:helyx_event, notice})
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
    defp bg_session(dir, answers, opts \\ []) do
      {foreground, opts} = Keyword.pop(opts, :foreground, false)
      core = start_core()
      gate = Path.join(dir, "gate")
      call = bash_call("c1", gate, true)

      calls =
        if foreground,
          do: [call, bash_call("c2", Path.join(dir, "foreground"), false)],
          else: [call]

      :ok = Helyx.Provider.Fake.script(core, "bg", [calls, ["started"] | answers])

      {:ok, session} =
        Helyx.Session.start(
          core,
          [model: "fake/bg", cwd: dir] ++ Keyword.put_new(opts, :sessions_dir, dir)
        )

      {:ok, _, _} = Helyx.Session.subscribe(session)
      %{core: core, session: session, gate: gate}
    end

    defp bash_call(id, file, background) do
      command = "until [ -e '#{file}' ]; do sleep 0.2; done"
      args = %{"command" => command, "background" => background}
      %Helyx.Message.ToolCall{id: id, name: "bash", arguments: args}
    end

    # The run process of `main/2` is back in its wait with an empty mailbox,
    # after a call to the session, which orders every event sent before it.
    # Returns its pid.
    defp await_print_wait(task, session) do
      :sys.get_state(Helyx.Session.pid(session))
      {:monitors, [process: run_pid]} = Process.info(task.pid, :monitors)
      waiting = [message_queue_len: 0, current_function: {Print, :wait, 2}]

      wait_until(fn ->
        Process.info(run_pid, [:message_queue_len, :current_function]) == waiting
      end)

      run_pid
    end

    defp turn_end do
      assert_receive {:helyx_event, %Helyx.Event{type: :turn_end, data: data}}
      data
    end

    @tag :tmp_dir
    test "print mode waits for a background run; its end opens the last turn", %{tmp_dir: dir} do
      %{session: session, gate: gate} = bg_session(dir, [["finished"]])
      test = self()

      # Had print mode ended at the first turn, stdout would hold "started".
      assert {0, "finished\n", stderr} =
               io("", fn ->
                 task = Task.async(fn -> run(session, "q", test) end)
                 assert turn_end() == %{outcome: :done}
                 File.write!(gate, "")
                 assert turn_end() == %{outcome: :done}
                 Task.await(task, :infinity)
               end)

      assert stderr =~ ~r/\Ahelyx: session \S+\nhelyx: waiting for background runs: 1\n\z/
    end

    @held_line "\nhelyx: background runs whose end did not reach the agent: 1\n"

    @tag :tmp_dir
    test "an end held between turns ends print mode with the last answer, one line, and 1",
         %{tmp_dir: dir} do
      %{session: session, gate: gate} = bg_session(dir, [])
      test = self()

      assert {1, "started\n", stderr} =
               io("", fn ->
                 task = Task.async(fn -> run(session, "q", test) end)
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
    @tag :tmp_dir
    test "a normal turn end with a held end gives the answer and 1",
         %{tmp_dir: dir} do
      %{session: session} = bg_session(dir, [], foreground: true)
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
                 task = Task.async(fn -> run(session, "q", test) end)
                 assert_receive {:helyx_event, %Helyx.Event{type: :tool_execution_end}}
                 send(await_print_wait(task, session), {:helyx_event, hold})
                 File.write!(Path.join(dir, "foreground"), "")
                 assert turn_end() == %{outcome: :done}
                 Task.await(task, :infinity)
               end)

      assert stderr =~ @held_line
    end

    defp one_call_session(dir, args) do
      core = start_core()
      call = %Helyx.Message.ToolCall{id: "c1", name: "bash", arguments: args}
      :ok = Helyx.Provider.Fake.script(core, "one", [[call], ["answered"]])
      {:ok, session} = Helyx.Session.start(core, model: "fake/one", cwd: dir, sessions_dir: dir)
      session
    end

    # The session counts the runs (`Helyx.Session.Queue`); print mode reads
    # no result text.
    @tag :tmp_dir
    test "a foreground result that opens with the start line opens no run", %{tmp_dir: dir} do
      line = ~s(<background id="abcdefghijkl" status="started">\\nfixture\\n)
      session = one_call_session(dir, %{"command" => "printf '#{line}'"})

      assert {0, "answered\n", stderr} = io("", fn -> run(session, "q") end)
      assert stderr =~ ~r/\Ahelyx: session \S+\n\z/
    end

    @tag :tmp_dir
    test "a background call whose result is an error opens no run", %{tmp_dir: dir} do
      args = %{"command" => "true", "background" => true, "timeout" => 0}
      session = one_call_session(dir, args)

      assert {0, "answered\n", stderr} = io("", fn -> run(session, "q") end)
      assert stderr =~ ~r/\Ahelyx: session \S+\n\z/
    end

    @tag :tmp_dir
    test "a resumed session closes its lost runs in the prompt turn", %{tmp_dir: dir} do
      sessions = Path.join(dir, "sessions")
      %{core: core, session: one} = bg_session(dir, [["resumed"]], sessions_dir: sessions)
      :ok = Helyx.Session.prompt(one, "q")
      assert turn_end() == %{outcome: :done}
      GenServer.stop(Helyx.Session.pid(one))
      wait_until(fn -> Helyx.Session.pid(one) == nil end)

      {:ok, two} = Helyx.Session.resume(core, sessions_dir: sessions, cwd: dir)
      assert {0, "resumed\n", _stderr} = io("", fn -> run(two, "again") end)
    end

    for {signal, status} <- [sigterm: 143, sighup: 129] do
      @tag :tmp_dir
      test "#{signal} during the wait for a background run halts with #{status}",
           %{tmp_dir: dir} do
        %{session: session} = bg_session(dir, [])
        test = self()

        io("", fn ->
          task = Task.async(fn -> run(session, "q", test) end)
          assert turn_end() == %{outcome: :done}
          run_pid = await_print_wait(task, session)
          :gen_event.notify(:erl_signal_server, unquote(signal))
          assert_receive {:halt, unquote(status)}
          # In the VM the halt ends the run process, which still waits.
          Process.exit(run_pid, :kill)
          end_wait(task)
        end)

        refute_received {:halt, _}
      end
    end

    test "a session that stops while the turn runs returns 1" do
      test = self()
      gate = Helyx.Test.Gate.open()
      {:ok, session} = Helyx.Session.start(start_core(), model: "gated/" <> gate)

      assert {1, "", stderr} =
               io("", fn ->
                 task = Task.async(fn -> run(session, "fail", test) end)
                 assert_receive {:waiting, _}
                 GenServer.stop(Helyx.Session.pid(session))
                 Task.await(task, :infinity)
               end)

      assert stderr =~ ~r/\nhelyx: the session stopped\n\z/
    end
  end
end
