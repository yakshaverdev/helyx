defmodule CodingAgent.LogFile do
  @moduledoc """
  Holds the log of the VM while the TUI owns the terminal: no log line
  reaches the terminal, and the lines go to a file
  (`docs/features/coding-agent.md`, "TUI", #832).
  """

  # The id of the drop filter on `:default`, and of the file handler.
  @filter :helyx_tui_log
  @handler :helyx_tui_log

  # The rotation threshold of the log file of a TUI run. The handler
  # writes a whole log record, then rotates when the file is over this
  # size, so a file can pass it by one record. It keeps one older file.
  @max_log_bytes 10_485_760

  @typedoc "`:ok` when the lines go to the file, or the notice of a run with no file log."
  @type held() :: :ok | {:error, String.t()}

  @doc """
  Runs `fun` with the log held: the file handler `:helyx_tui_log` writes
  the events to `path`, then a filter on the `:default` handler drops
  every event, and the events that `:default` has queued go to the
  terminal before `fun` starts. `fun` gets `:ok`, or `{:error, notice}`
  when `path` is there and not a regular file, or does not open: then no
  file log runs, and no line reaches the terminal either. At the end the
  filter on `:default` goes, then a filter closes the file handler, also
  when `fun` raises; the file handler stays for the next hold. A call
  while a live process holds runs `fun` in that hold, with its result;
  one process holds at a time. Returns the result of `fun`.
  """
  @spec run(Path.t(), (held() -> result)) :: result when result: term()
  def run(path, fun) do
    {:ok, default} = :logger.get_handler_config(:default)

    case List.keyfind(default.filters, @filter, 0) do
      nil ->
        hold(path, default, fun)

      {@filter, {_drop, {holder, held}}} ->
        if Process.alive?(holder) do
          fun.(held)
        else
          # A holder that was killed left its filter: the hold is over.
          _ = :logger.remove_handler_filter(:default, @filter)
          hold(path, default, fun)
        end
    end
  end

  defp hold(path, default, fun) do
    held = path |> check() |> open(path, default) |> notice(path)
    # From here on no new line reaches the terminal. Before, a line goes
    # to the terminal and to the file. A call inside the hold reads the
    # holder and `held` from the filter.
    :ok = :logger.add_handler_filter(:default, @filter, {&__MODULE__.drop/2, {self(), held}})

    try do
      # The lines that `:default` queued before the filter, and its notice
      # of a mode change, go to the terminal before the TUI owns it: the
      # call returns after the handler process wrote them, or gives
      # `handler_busy` after 5,000 ms. A `:default` of another module has
      # no such process and is not drained.
      _ = if default.module == :logger_std_h, do: :logger_std_h.filesync(:default)
      fun.(held)
    after
      # A line between the two goes to both.
      _ = :logger.remove_handler_filter(:default, @filter)
      close()
    end
  end

  @doc false
  # The filter of the hold on `:default`, and the one that closes the file
  # handler. Its argument holds the state of the hold, which a call inside
  # it reads.
  @spec drop(:logger.log_event(), term()) :: :stop
  def drop(_event, _args), do: :stop

  # The file handler stays open, so its buffer goes to the file here: the
  # VM can halt right after the TUI. With no handler, or one that is
  # closed already, there is nothing to write.
  defp close do
    case :logger.add_handler_filter(@handler, @filter, {&__MODULE__.drop/2, :closed}) do
      :ok -> :logger_std_h.filesync(@handler)
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
  defp open(:ok, path, default) do
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
        add(file, default)

      {:error, {:not_found, @handler}} ->
        add(file, default)
    end
  end

  defp open(error, _path, _default), do: error

  defp add(file, default) do
    config = %{file: file, max_no_bytes: @max_log_bytes, max_no_files: 1}

    # The drop filter of a killed holder is not copied.
    handler =
      default
      |> Map.take([:level, :formatter, :filter_default])
      |> Map.put(:filters, List.keydelete(default.filters, @filter, 0))

    case :logger.add_handler(@handler, :logger_std_h, Map.put(handler, :config, config)) do
      :ok -> :ok
      {:error, {:handler_not_added, {:open_failed, _file, reason}}} -> {:error, posix(reason)}
    end
  end

  defp notice(:ok, _path), do: :ok

  defp notice({:error, why}, path),
    do: {:error, CodingAgent.clean_line("no log file for this run (#{why}): #{path}")}

  defp posix(reason), do: "does not open: " <> to_string(:file.format_error(reason))
end
