defmodule CodingAgent.PrintTest do
  # Not async: print mode swaps the handler of the VM's signal server, and
  # the CLI runs Core under its default name.
  use ExUnit.Case, async: false

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
    # piped bytes, nil for a terminal that must not be read, or a signal that
    # a read sends to the signal server in place of a reply. `write` is `:ok`,
    # or a signal that a write sends in place of a reply, as a full pipe
    # blocks. The output is kept for `output/1`.
    def start(stdin?, input, write \\ :ok) do
      state = %{stdin: stdin?, input: input, write: write, encoding: :unicode, out: []}
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
          if reply != :no_reply, do: send(from, {:io_reply, reply_as, reply})
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

    defp request({:put_chars, :unicode, chars}, %{write: :ok} = state),
      do: {:ok, %{state | out: [IO.chardata_to_string(chars) | state.out]}}

    defp request({:put_chars, :unicode, _chars}, %{write: signal} = state) do
      :gen_event.notify(:erl_signal_server, signal)
      {:no_reply, state}
    end

    defp request({:get_chars, _encoding, _prompt, _count}, %{input: nil} = state),
      do: {{:error, :read_from_tty}, state}

    defp request({:get_chars, _encoding, _prompt, _count}, %{input: signal} = state)
         when is_atom(signal) do
      :gen_event.notify(:erl_signal_server, signal)
      {:no_reply, state}
    end

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

  alias CodingAgent.{CLI, Print}

  @max Print.max_stdin_bytes()

  # Runs `fun` with `input` piped on stdin (a binary, or a signal that the
  # read sends), or with a terminal on stdin when `input` is `:tty`, and
  # returns its result, stdout, and stderr.
  defp io(input, fun, write \\ :ok) do
    device =
      if input == :tty,
        do: Device.start(true, nil, write),
        else: Device.start(false, input, write)

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

  defp signal_handlers, do: Enum.sort(:gen_event.which_handlers(:erl_signal_server))

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
      handlers = signal_handlers()

      assert {0, "-x say this\n", "helyx: session " <> id} =
               io("", fn -> CLI.main(["-p", "-x say this", "--model", "fake/echo", dir]) end)

      assert signal_handlers() == handlers
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
                 CLI.main(["--print", "why", "--model", "fake/echo", dir])
               end)

      # The echo model sends the words back, so whitespace runs keep their place.
      assert out == "why\n\n<stdin>\nline one\nline two\n</stdin>\n"
    end

    test "a failed turn prints nothing on stdout and returns 1", %{tmp_dir: dir} do
      assert {1, "", stderr} =
               io("", fn -> CLI.main(["-p", "x", "--model", "fake/unscripted", dir]) end)

      # The log of Core goes to stderr too, so the line is not the last one.
      assert stderr =~ ~s(\nhelyx: the turn failed: {:no_script, "unscripted"}\n)
    end

    test "input over the bound fails before anything starts", %{tmp_dir: dir, sessions: s} do
      line = "helyx: the piped input is over the #{@max}-byte limit\n"

      assert {1, "", ^line} =
               io(String.duplicate("a", @max + 1), fn -> CLI.main(["-p", "x", dir]) end)

      refute File.exists?(s)
      assert Process.whereis(Helyx.Core) == nil
    end

    test "-p does not combine with a resume or the list" do
      for {argv, text} <- [
            {["-p", "x", "--resume"], "--print does not combine with --resume; a print run"},
            {["-p", "x", "--session", "abc"], "--print does not combine with --session"},
            {["-p", "x", "--list"], "--print does not combine with --list"}
          ] do
        assert {1, "", "helyx: " <> line} = io("", fn -> CLI.main(argv) end)
        assert line =~ text
      end

      assert {1, "", stderr} = io("", fn -> CLI.main(["-p"]) end)
      assert stderr =~ ~s("-p"; the options)
    end

    test "SIGTERM while stdin is read returns 143 with nothing started", %{sessions: s} do
      handlers = signal_handlers()
      assert io(:sigterm, fn -> CLI.main(["-p", "x"]) end) == {143, "", ""}

      assert signal_handlers() == handlers
      refute File.exists?(s)
      assert Process.whereis(Helyx.Core) == nil
    end

    test "a signal while Core starts sends no prompt and stops Core", %{tmp_dir: dir} do
      # The signal handler sends this message; it waits in the mailbox.
      send(self(), {Print, :signal, 143})

      assert {143, "", "helyx: session " <> _} =
               io(:tty, fn -> CLI.main(["-p", "x", "--model", "fake/echo", dir]) end)

      assert Process.whereis(Helyx.Core) == nil
      # No prompt went to the session, so it has nothing to list.
      assert capture_io(fn -> CLI.main(["--list", dir]) end) == ""
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
    test "an answer cut at the token limit is printed and returns 1" do
      {:ok, session} = Helyx.Session.start(start_core(), model: "stop/max_tokens")

      assert {1, "cut\n", stderr} = io("", fn -> Print.run(session, "q") end)
      assert stderr =~ ~r/\Ahelyx: session \S+\nhelyx: the answer stopped at the token limit\n\z/
    end

    test "a refused answer is printed with a notice and returns 0" do
      {:ok, session} = Helyx.Session.start(start_core(), model: "stop/refused")

      assert {0, "cut\n", stderr} = io("", fn -> Print.run(session, "q") end)
      assert stderr =~ "helyx: the answer stopped: the provider refused or filtered it\n"
    end

    test "wrap/1 sends the log to stderr, and puts the handler back" do
      {:ok, before} = :logger.get_handler_config(:default)

      assert Print.wrap(fn -> :logger.get_handler_config(:default) end) ==
               {:ok, put_in(before.config.type, :standard_error)}

      assert :logger.get_handler_config(:default) == {:ok, before}
    end

    test "SIGTERM during the turn returns 143, and SIGHUP gives 129" do
      gate = Helyx.Test.Gate.open()
      {:ok, session} = Helyx.Session.start(start_core(), model: "gated/" <> gate)

      assert {143, "", _} =
               io("", fn ->
                 task = Task.async(fn -> Print.wrap(fn -> Print.run(session, "fail") end) end)
                 assert_receive {:waiting, _}
                 :gen_event.notify(:erl_signal_server, :sigterm)
                 Task.await(task, :infinity)
               end)

      assert Print.wrap(fn ->
               :gen_event.sync_notify(:erl_signal_server, :sighup)
               :ok
             end) == 129
    end

    test "the first signal sets the status" do
      # The read or the wait takes the first message; no second one waits.
      assert Print.wrap(fn ->
               :gen_event.sync_notify(:erl_signal_server, :sigterm)
               :gen_event.sync_notify(:erl_signal_server, :sighup)
               assert_received {Print, :signal, status}
               status
             end) == 143
    end

    test "a signal while the answer write blocks returns its status" do
      {:ok, session} = Helyx.Session.start(start_core(), model: "fake/echo")

      assert {143, "", _} =
               io("", fn -> Print.wrap(fn -> Print.run(session, "q") end) end, :sigterm)
    end

    test "an aborted turn prints nothing on stdout and returns 1" do
      gate = Helyx.Test.Gate.open()
      {:ok, session} = Helyx.Session.start(start_core(), model: "gated/" <> gate)

      assert {1, "", stderr} =
               io("", fn ->
                 task = Task.async(fn -> Print.run(session, "fail") end)
                 assert_receive {:waiting, _}
                 :ok = Helyx.Session.abort(session)
                 Task.await(task, :infinity)
               end)

      assert stderr =~ ~r/\nhelyx: the turn was aborted\n\z/
    end

    test "a notice goes to stderr as one line of at most 4000 bytes" do
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

      assert {143, "", stderr} =
               io("", fn ->
                 task = Task.async(fn -> Print.run(session, "fail") end)
                 assert_receive {:waiting, _}
                 send(task.pid, {:helyx_event, notice})
                 send(task.pid, {Print, :signal, 143})
                 Task.await(task, :infinity)
               end)

      assert [_session, "helyx: " <> line] = String.split(stderr, "\n", trim: true)
      assert byte_size(line) <= 4000
      assert line =~ ~r/\An+/
    end

    test "a session that stops while the turn runs returns 1" do
      gate = Helyx.Test.Gate.open()
      {:ok, session} = Helyx.Session.start(start_core(), model: "gated/" <> gate)

      assert {1, "", stderr} =
               io("", fn ->
                 task = Task.async(fn -> Print.run(session, "fail") end)
                 assert_receive {:waiting, _}
                 GenServer.stop(Helyx.Session.pid(session))
                 Task.await(task, :infinity)
               end)

      assert stderr =~ ~r/\nhelyx: the session stopped\n\z/
    end
  end
end
