defmodule CodingAgent.PrintSignalTest do
  # Each test runs print mode in its own OS process, with real pipes, and
  # sends it a real signal.
  use ExUnit.Case, async: true

  alias CodingAgent.Print

  @moduletag :slow
  @moduletag :tmp_dir

  # The halt comes at most `abort_ms` after the signal; the margin is for a
  # loaded machine and the start of the VM.
  @load_ms 5_000

  # `$1` is the folder, `$2` the case, the rest the command. A writer of
  # zeros fills the pipe of stdout or stderr, and `sleep` holds the read end
  # open and never reads it. For `stdin`, `sleep` holds stdin open and sends
  # nothing. `bad_stdin` fills stderr and pipes a byte that is not UTF-8.
  # The exit status of the command goes to the file `status`.
  @script ~S"""
  dir=$1; mode=$2; shift 2
  case $mode in
    stdout) { cat /dev/zero & "$@" </dev/null 2>"$dir/err"; echo $? >"$dir/status"; kill $!; } | sleep 20 ;;
    stderr) { cat /dev/zero >&2 & "$@" </dev/null; echo $? >"$dir/status"; kill $!; } 2>&1 >/dev/null | sleep 20 ;;
    stdin) sleep 20 | { "$@" >/dev/null 2>&1; echo $? >"$dir/status"; } ;;
    bad_stdin) { cat /dev/zero >&2 & printf '\377' | "$@"; echo $? >"$dir/status"; kill $!; } 2>&1 >/dev/null | sleep 20 ;;
  esac
  """

  # A print run on the echo model.
  @run ~S"""
  System.halt(CodingAgent.CLI.main(["-p", "x", "--model", "fake/echo", dir]))
  """

  for {mode, signal, status} <- [
        {"stdout", "TERM", "143"},
        {"stderr", "TERM", "143"},
        {"stdin", "TERM", "143"},
        {"stdin", "HUP", "129"}
      ] do
    test "SIG#{signal} with #{mode} blocked ends the run with #{status} in the bound",
         %{tmp_dir: dir} do
      pid = start(dir, unquote(mode), @run)
      if unquote(mode) == "stdout", do: await_answer(dir)
      {_, 0} = System.cmd("kill", ["-#{unquote(signal)}", pid])

      assert await_file(Path.join(dir, "status"), Print.abort_ms() + @load_ms) ==
               unquote(status) <> "\n"
    end
  end

  test "SIGTERM with log output and stdout blocked ends the run with 143", %{tmp_dir: dir} do
    # The default log handler writes to the full stdout pipe, so the swap of
    # the log handler blocks.
    log = ~S"""
    spawn(fn -> Enum.each(1..100, fn _ -> :logger.warning(~c"queued") end) end)
    Process.sleep(200)
    """

    pid = start(dir, "stdout", log <> @run)
    {_, 0} = System.cmd("kill", ["-TERM", pid])
    assert await_file(Path.join(dir, "status"), Print.abort_ms() + @load_ms) == "143\n"
  end

  test "SIGTERM with the error line blocked on stderr ends the run with 143",
       %{tmp_dir: dir} do
    pid = start(dir, "bad_stdin", @run)
    {_, 0} = System.cmd("kill", ["-TERM", pid])
    assert await_file(Path.join(dir, "status"), Print.abort_ms() + @load_ms) == "143\n"
  end

  test "a SIGHUP after the run ends, while the stop of a SIGTERM waits, keeps 143",
       %{tmp_dir: dir} do
    # The halt of the stop waits `abort_ms`, as a slow abort does. The run
    # returns 2 s after print mode starts, between the two signals.
    run = ~S"""
    halt = fn status ->
      Process.sleep(CodingAgent.Print.abort_ms())
      :erlang.halt(status, flush: false)
    end

    CodingAgent.Print.main(fn -> Process.sleep(2_000) && 0 end, halt)
    """

    pid = start(dir, "stdin", run)
    {_, 0} = System.cmd("kill", ["-TERM", pid])
    Process.sleep(2_000)
    {_, 0} = System.cmd("kill", ["-HUP", pid])
    assert await_file(Path.join(dir, "status"), Print.abort_ms() + @load_ms) == "143\n"
  end

  # Starts `elixir` with the code of this build and `HOME` in `dir`: it runs
  # `run`, with `dir` bound, and writes its OS pid once the print handler is
  # in the signal server. Returns the pid once the file holds it.
  defp start(dir, mode, run) do
    paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])
    pid_file = Path.join(dir, "pid")

    code = """
    spawn(fn ->
      ready? = fn -> CodingAgent.Print.Signal in :gen_event.which_handlers(:erl_signal_server) end
      Stream.repeatedly(fn -> ready?.() or Process.sleep(10) end) |> Enum.find(&(&1 == true))
      File.write!(#{inspect(pid_file)}, System.pid())
    end)

    dir = #{inspect(dir)}
    #{run}
    """

    args = ["-c", @script, "sh", dir, mode, System.find_executable("elixir")] ++ paths
    args = args ++ ["-e", code]

    Port.open({:spawn_executable, System.find_executable("sh")}, [
      :binary,
      :nouse_stdio,
      args: args,
      env: [{~c"HOME", String.to_charlist(dir)}]
    ])

    pid = await_file(pid_file, @load_ms)
    # The run reaches the read of stdin, a blocked write, or its wait.
    Process.sleep(1_000)
    pid
  end

  # The session file holds the answer once the turn has ended; the write to
  # stdout comes next.
  defp await_answer(dir) do
    await(@load_ms, fn ->
      Path.wildcard(Path.join(dir, ".helyx/sessions/**/*.jsonl"))
      |> Enum.any?(&(File.read!(&1) =~ "assistant"))
    end)
  end

  defp await_file(path, ms) do
    await(ms, fn -> File.exists?(path) and File.read!(path) != "" end)
    File.read!(path)
  end

  defp await(ms, fun), do: await_until(System.monotonic_time(:millisecond) + ms, fun)

  defp await_until(deadline, fun) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("the condition did not hold in time")

      true ->
        Process.sleep(50) && await_until(deadline, fun)
    end
  end
end
