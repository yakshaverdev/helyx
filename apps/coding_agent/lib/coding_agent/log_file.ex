defmodule CodingAgent.LogFile do
  @moduledoc """
  Holds the log of the VM while the TUI owns the terminal: no log line
  reaches the terminal, and the lines go to a file
  (`docs/features/coding-agent.md`, "TUI", #832).
  """

  # The id of the drop filter on `:default`, and of the file handler.
  @filter :helyx_tui_log
  @handler :helyx_tui_log

  # The key of the state of the hold: the holder and `held`. It is not in
  # the logger config: a `:logger.remove_handler/1` writes back the
  # primary config that it read at its start, so a change between is lost.
  @hold {__MODULE__, :hold}

  # The rotation threshold of a log file: the sink of the TUI holds at this
  # size, and the sink of `server.log` starts a new file before a write
  # would pass it. One path a product writes gets one cap.
  @max_log_bytes 10_485_760

  @typedoc "`:ok` when the lines go to the file, or the notice of a run with no file log."
  @type held() :: :ok | {:error, String.t()}

  @doc """
  The cap of a log file, in bytes, before the sink rotates it: the log of
  the TUI at this size and the log of `server.log` before a write passes
  it. Each keeps one older file, `<path>.0`.
  """
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_log_bytes

  @doc """
  Runs `fun` with the log held: the file handler `:helyx_tui_log` writes
  the events to `path`, then a filter on the `:default` handler drops
  every event, and the events that `:default` has queued go to the
  terminal before `fun` starts. With no `:default` there is no terminal
  handler to filter or drain, and the file handler writes in the format
  of the Elixir logger. `fun` gets `:ok`, or `{:error, notice}` when
  `path` is there and not a regular file, or does not open: then no file
  log runs, and no line reaches the terminal either. At the end the
  filter on `:default` goes, then a filter closes the file handler, also
  when `fun` raises; the file handler stays for the next hold. A call
  while a live process holds runs `fun` in that hold, with its result;
  one process holds at a time. Returns the result of `fun`.
  """
  @spec run(Path.t(), (held() -> result)) :: result when result: term()
  def run(path, fun) do
    case :persistent_term.get(@hold, nil) do
      nil ->
        hold(path, fun)

      {holder, held} ->
        if Process.alive?(holder) do
          fun.(held)
        else
          # A holder that was killed left its state: the hold is over.
          release()
          hold(path, fun)
        end
    end
  end

  defp hold(path, fun) do
    held = path |> check() |> open(path) |> notice(path)
    # A call inside the hold reads the holder and `held` here.
    :ok = :persistent_term.put(@hold, {self(), held})

    try do
      # From here on no new line reaches the terminal. Before, a line goes
      # to the terminal and to the file.
      hush()
      drain()
      fun.(held)
    after
      release()
      close()
    end
  end

  # A config can turn `:default` off (`:default_handler` false), and the
  # logger removes it while it restarts it after an overload kill: then
  # there is no terminal handler to filter. The restart adds it back with
  # the filters it had at the kill, so it can have the drop filter.
  defp hush do
    case :logger.add_handler_filter(:default, @filter, {&__MODULE__.drop/2, :held}) do
      :ok -> :ok
      {:error, {:not_found, :default}} -> :ok
      {:error, {:already_exist, @filter}} -> :ok
    end
  end

  # The lines that `:default` queued before the filter, and its notice of
  # a mode change, go to the terminal before the TUI owns it: the call
  # returns after the handler process wrote them, or gives `handler_busy`
  # after 5,000 ms. A `:default` of another module has no such process
  # and is not drained.
  defp drain do
    case :logger.get_handler_config(:default) do
      {:ok, %{module: :logger_std_h}} -> sync(:default)
      _none_or_other -> :ok
    end
  end

  # A line between the removal of the drop filter and the close goes to
  # both. The filter can be gone already.
  defp release do
    _ = :logger.remove_handler_filter(:default, @filter)
    _ = :persistent_term.erase(@hold)
    :ok
  end

  # A handler process that ends during the call has nothing more to
  # write: an overload kill of `:default`, or a file handler whose file
  # failed, which the logger removes.
  defp sync(handler) do
    _ = :logger_std_h.filesync(handler)
    :ok
  catch
    :exit, {_reason, {:gen_server, :call, _args}} -> :ok
  end

  @doc false
  # The filter of the hold on `:default`, and the one that closes the file
  # handler.
  @spec drop(:logger.log_event(), term()) :: :stop
  def drop(_event, _args), do: :stop

  # The file handler stays open, so its buffer goes to the file here: the
  # VM can halt right after the TUI. With no handler, or one that is
  # closed already, there is nothing to write.
  defp close do
    case :logger.add_handler_filter(@handler, @filter, {&__MODULE__.drop/2, :closed}) do
      :ok -> sync(@handler)
      {:error, _not_found_or_closed} -> :ok
    end
  end

  # `lstat` opens nothing and follows no link: a FIFO is refused before an
  # open could block the logger.
  defp check(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: :directory}} -> {:error, "is a folder"}
      {:ok, %File.Stat{type: :symlink}} -> {:error, "is a symbolic link"}
      {:ok, %File.Stat{}} -> {:error, "is not a regular file"}
      {:error, reason} -> {:error, posix(reason)}
    end
  end

  # The file handler of an earlier hold on `path` opens again. One on
  # another path goes first: a process that logs at that moment can get
  # `removed_failing_handler` on the terminal, but the CLI holds one path.
  defp open(:ok, path) do
    # `logger_std_h` keeps the absolute name.
    file = path |> Path.absname() |> String.to_charlist()

    case :logger.get_handler_config(@handler) do
      # No closing filter is there when the process of the last hold was
      # killed.
      {:ok, %{config: %{file: ^file}}} ->
        _ = :logger.remove_handler_filter(@handler, @filter)
        :ok

      {:ok, _other} ->
        :ok = :logger.remove_handler(@handler)
        add(file)

      {:error, {:not_found, @handler}} ->
        add(file)
    end
  end

  defp open(error, _path), do: error

  defp add(file) do
    config = %{file: file, max_no_bytes: @max_log_bytes, max_no_files: 1}
    handler = Map.put(settings(), :config, config)

    case :logger.add_handler(@handler, :logger_std_h, handler) do
      :ok -> :ok
      {:error, {:handler_not_added, {:open_failed, _file, reason}}} -> {:error, posix(reason)}
    end
  end

  # The file handler writes as `:default` does; the drop filter of a
  # killed holder is not copied. With no `:default`, it writes in the
  # format of the Elixir logger.
  defp settings do
    case :logger.get_handler_config(:default) do
      {:ok, default} ->
        default
        |> Map.take([:level, :formatter, :filter_default])
        |> Map.put(:filters, List.keydelete(default.filters, @filter, 0))

      {:error, {:not_found, :default}} ->
        %{formatter: Logger.default_formatter()}
    end
  end

  defp notice(:ok, _path), do: :ok

  defp notice({:error, why}, path),
    do: {:error, CodingAgent.clean_line("no log file for this run (#{why}): #{path}")}

  defp posix(reason), do: "does not open: " <> to_string(:file.format_error(reason))
end
