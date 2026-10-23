defmodule CodingAgent.LogFileTest do
  # The hold changes the log handlers of the VM, which every test shares,
  # and one process holds at a time, so this module runs alone.
  use ExUnit.Case, async: false

  alias CodingAgent.LogFile

  require Logger

  @moduletag :tmp_dir

  # The hold of a bad path opens nothing, so it ends at once; this margin
  # for load only turns a blocked open into a failure, not a stuck run.
  @load_ms 10_000

  test "the log goes to the file while the hold runs, then the handlers are as before",
       %{tmp_dir: dir} do
    {:ok, default} = :logger.get_handler_config(:default)
    path = Path.join(dir, "tui.log")

    assert LogFile.run(path, fn held ->
             assert held == :ok
             assert {:ok, %{config: %{file: file}}} = :logger.get_handler_config(:helyx_tui_log)
             assert file == String.to_charlist(path)
             assert dropping?()
             refute closed?()
             Logger.error("log file marker")
             :result
           end) == :result

    assert :logger.get_handler_config(:default) == {:ok, default}
    assert closed?()
    assert File.read!(path) =~ "log file marker"

    # The file handler stays, closed, and opens again for the next hold.
    ExUnit.CaptureLog.capture_log(fn -> Logger.error("after the hold") end)
    LogFile.run(path, fn :ok -> Logger.error("second hold") end)
    :ok = :logger_std_h.filesync(:helyx_tui_log)
    assert File.read!(path) =~ "second hold"
    refute File.read!(path) =~ "after the hold"

    # A raise puts the handlers back too.
    assert_raise RuntimeError, fn -> LogFile.run(path, fn _ -> raise "x" end) end
    assert :logger.get_handler_config(:default) == {:ok, default}
    assert closed?()
  end

  test "a hold on another path writes to that path", %{tmp_dir: dir} do
    first = Path.join(dir, "first.log")
    second = Path.join(dir, "second.log")
    LogFile.run(first, fn :ok -> Logger.error("to the first") end)
    LogFile.run(second, fn :ok -> Logger.error("to the second") end)
    :ok = :logger_std_h.filesync(:helyx_tui_log)
    assert File.read!(second) =~ "to the second"
    refute File.read!(second) =~ "to the first"
  end

  test "a call inside a hold runs in the outer hold, with its result", %{tmp_dir: dir} do
    {:ok, default} = :logger.get_handler_config(:default)
    outer = Path.join(dir, "tui.log")
    inner = Path.join(dir, "inner.log")

    LogFile.run(outer, fn :ok ->
      assert LogFile.run(inner, fn held -> held end) == :ok
      # The inner call changed nothing: the outer hold still holds.
      assert dropping?()
      assert {:ok, %{config: %{file: file}}} = :logger.get_handler_config(:helyx_tui_log)
      assert file == String.to_charlist(outer)
    end)

    refute File.exists?(inner)

    File.mkdir!(Path.join(dir, "folder"))

    LogFile.run(Path.join(dir, "folder"), fn {:error, notice} ->
      assert LogFile.run(outer, fn held -> held end) == {:error, notice}
    end)

    assert :logger.get_handler_config(:default) == {:ok, default}
  end

  test "a holder that was killed leaves no hold", %{tmp_dir: dir} do
    test = self()

    holder =
      spawn(fn ->
        LogFile.run(Path.join(dir, "first.log"), fn :ok ->
          send(test, :holding)
          Process.sleep(:infinity)
        end)
      end)

    assert_receive :holding
    ref = Process.monitor(holder)
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^ref, :process, ^holder, :killed}

    second = Path.join(dir, "second.log")
    LogFile.run(second, fn :ok -> Logger.error("to the second") end)
    :ok = :logger_std_h.filesync(:helyx_tui_log)
    assert File.read!(second) =~ "to the second"
    refute dropping?()
  end

  # A config can give `:default` another module, which has no process to
  # drain: the hold runs with no drain.
  test "a :default of another module is not drained", %{tmp_dir: dir} do
    {:ok, default} = :logger.get_handler_config(:default)
    :ok = :logger.remove_handler(:default)

    try do
      :ok = :logger.add_handler(:default, :logger_disk_log_h, %{config: %{file: ~c"#{dir}/disk"}})
      assert LogFile.run(Path.join(dir, "tui.log"), fn :ok -> :ran end) == :ran
    after
      _ = :logger.remove_handler(:default)
      :ok = :logger.add_handler(:default, default.module, default)
    end
  end

  describe "a bad tui.log gives one notice and a run with no file log" do
    test "a folder", %{tmp_dir: dir} do
      path = Path.join(dir, "tui.log")
      File.mkdir!(path)
      assert bad(path) =~ "no log file for this run (is a folder): #{path}"
    end

    test "a file with no write access", %{tmp_dir: dir} do
      path = Path.join(dir, "tui.log")
      File.write!(path, "")
      File.chmod!(path, 0o400)
      assert bad(path) =~ "(does not open: permission denied): #{path}"
    end

    test "a folder in which no file can be made", %{tmp_dir: dir} do
      File.chmod!(dir, 0o500)
      on_exit(fn -> File.chmod!(dir, 0o700) end)
      assert bad(Path.join(dir, "tui.log")) =~ "(does not open: permission denied): "
    end

    test "a dangling link, and a link to a regular file", %{tmp_dir: dir} do
      path = Path.join(dir, "tui.log")
      File.ln_s!(Path.join(dir, "missing"), path)
      assert bad(path) =~ "(is a symbolic link): #{path}"
      refute File.exists?(Path.join(dir, "missing"))

      File.write!(Path.join(dir, "real"), "")
      path = Path.join(dir, "linked.log")
      File.ln_s!(Path.join(dir, "real"), path)
      assert bad(path) =~ "(is a symbolic link): #{path}"
      assert File.read!(Path.join(dir, "real")) == ""
    end

    test "a FIFO with no reader opens nothing", %{tmp_dir: dir} do
      path = Path.join(dir, "tui.log")
      {_, 0} = System.cmd("mkfifo", [path])
      assert bad(path) =~ "(is not a regular file): #{path}"
    end

    test "a device", %{tmp_dir: _dir} do
      assert bad("/dev/null") =~ "no log file for this run (is not a regular file): /dev/null"
    end

    test "a path over the line bound gets the cut", %{tmp_dir: dir} do
      path = Path.join(dir, String.duplicate("a", 5000))
      notice = bad(path)
      assert notice =~ "no log file for this run (does not open: file name too long): "
      assert byte_size(notice) <= 4000
    end

    test "a path with a control character gets the clean pass", %{tmp_dir: dir} do
      path = Path.join(dir, "bad\nname")
      File.mkdir!(path)
      notice = bad(path)
      assert String.valid?(notice)
      refute notice =~ "\n"
    end
  end

  # The lines that `:default` queued before the hold go to the terminal
  # before `fun` starts, with the notices of its mode changes: in a VM of
  # its own, the handler process is held while five lines queue, and is let
  # go after the hold has begun.
  @tag :slow
  test "the queue of the terminal handler is written before fun starts", %{tmp_dir: dir} do
    ebin = Path.dirname(:code.which(LogFile))
    script = Path.join(dir, "queue.exs")

    File.write!(script, """
    require Logger
    :ok = :logger.update_handler_config(:default, :config, %{sync_mode_qlen: 1, drop_mode_qlen: 2})
    handler = Process.whereis(:logger_std_h_default)
    main = self()

    # Only the process that suspends can resume.
    helper =
      spawn(fn ->
        :erlang.suspend_process(handler)
        send(main, :suspended)
        receive do: (:go -> Process.sleep(200))
        :erlang.resume_process(handler)
      end)

    receive do: (:suspended -> :ok)
    for n <- 1..5, do: Logger.error("queued \#{n}")
    send(helper, :go)
    CodingAgent.LogFile.run(#{inspect(Path.join(dir, "tui.log"))}, fn :ok -> IO.puts("FUN STARTED") end)
    """)

    {out, 0} =
      System.cmd(System.find_executable("elixir"), ["-pa", ebin, script], stderr_to_stdout: true)

    [before, _after] = String.split(out, "FUN STARTED")
    assert before =~ "queued 1"
    assert before =~ "switched from"
  end

  # A Logger line of another process during the change of the handlers
  # reaches no terminal: in a VM of its own, so that its stderr is the
  # terminal. The loggers note each line whose log call ran inside one
  # hold, and stderr must show none of them, and no line of the logger
  # itself, such as `removed_failing_handler`. 300 holds of 10 ms: the
  # remove and add of `:default` before #832 printed 0 to 8 lines in 600.
  @tag :slow
  test "a process that logs during the change prints no line of a hold on stderr",
       %{tmp_dir: dir} do
    ebin = Path.dirname(:code.which(LogFile))
    elixir = System.find_executable("elixir")
    script = Path.join(dir, "swap.exs")
    File.write!(script, swap_script(Path.join(dir, "tui.log")))

    {out, 0} = System.cmd(elixir, ["-pa", ebin, script], stderr_to_stdout: true)

    [_, hidden] = Regex.run(~r/^HIDDEN (.*)$/m, out)
    hidden = hidden |> String.split(",", trim: true) |> MapSet.new()
    lines = out |> String.split("\n", trim: true) |> Enum.reject(&(&1 =~ ~r/^HIDDEN /))
    assert MapSet.size(hidden) > 0

    for line <- lines do
      assert line =~ ~r/\[error\] tick \d+$/
      [_, seq] = Regex.run(~r/tick (\d+)$/, line)
      refute MapSet.member?(hidden, seq)
    end
  end

  defp swap_script(path) do
    ~s'''
    require Logger
    count = :atomics.new(1, [])
    hidden = :ets.new(:hidden, [:public, :bag])

    # A log call that starts and ends in one hold (an odd count that did
    # not change) must not reach stderr.
    tick = fn tick, seq ->
      before = :atomics.get(count, 1)
      Logger.error("tick " <> Integer.to_string(seq))
      # A pause, so that `:default` does not reach its drop mode.
      Process.sleep(1)
      if before == :atomics.get(count, 1) and rem(before, 2) == 1,
        do: :ets.insert(hidden, {seq})
      tick.(tick, seq + 2)
    end

    loggers = for first <- [1, 2], do: spawn(fn -> tick.(tick, first) end)

    for _ <- 1..300 do
      CodingAgent.LogFile.run(#{inspect(path)}, fn :ok ->
        :atomics.add(count, 1, 1)
        Process.sleep(10)
        :atomics.add(count, 1, 1)
      end)
    end

    Enum.each(loggers, &Process.exit(&1, :kill))
    :logger_std_h.filesync(:default)
    seqs = for {seq} <- :ets.tab2list(hidden), do: Integer.to_string(seq)
    IO.puts("HIDDEN " <> Enum.join(seqs, ","))
    '''
  end

  # The hold of a bad path: the notice, no open file handler, the drop
  # filter in place, and `:default` as before at the end.
  defp bad(path) do
    {:ok, default} = :logger.get_handler_config(:default)

    task =
      Task.async(fn ->
        LogFile.run(path, fn held ->
          assert {:error, notice} = held
          assert closed?()
          assert dropping?()
          notice
        end)
      end)

    notice = Task.await(task, @load_ms)
    assert :logger.get_handler_config(:default) == {:ok, default}
    notice
  end

  # No file handler, or one with the closing filter.
  defp closed? do
    case :logger.get_handler_config(:helyx_tui_log) do
      {:ok, %{filters: filters}} -> List.keymember?(filters, :helyx_tui_log, 0)
      {:error, {:not_found, _}} -> true
    end
  end

  defp dropping? do
    {:ok, %{filters: filters}} = :logger.get_handler_config(:default)
    List.keymember?(filters, :helyx_tui_log, 0)
  end
end
