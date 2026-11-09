defmodule Helyx.Watchdog.Group do
  @moduledoc false
  # The release of the handles of `Helyx.Watchdog`: `{:command, group, record}`
  # for the command's process group and `{:watchdog, os_pid, record}` for the
  # watchdog, which is its own group. Returns the handles whose group still
  # has a process.
  #
  # Each group has one release record (`Helyx.Watchdog.Record`), which
  # every copy of its handle carries. A release takes the record of each
  # handle once, before any probe or signal: one that is gone is confirmed
  # with no signal, so a number that the OS gave to a new group is never
  # signalled; one that another release holds is waited for. A probe that
  # confirms a group gone writes it gone; the others end not confirmed.
  #
  # Command groups go first, then the watchdogs. A watchdog is a reaper: it
  # is swept only after every command group is gone or still held, because a
  # KILLed watchdog cannot reap its command, and where PID 1 does not reap
  # orphans the zombie would hold its group forever. It exits by itself once
  # the command is reaped; the KILL is the fallback for a watchdog that never
  # does. The watchdog ignores TERM, so only the command groups get one.
  #
  # `:deliver` KILLs straight away: the call is over, nothing in the group
  # has output anyone will read. `:cancel` TERMs first and KILLs after the
  # grace period (`Helyx.Watchdog.grace_ms/0`, or the `:grace_ms` option).
  #
  # No kill(1) run starts at or after the deadline: a skipped probe counts
  # the group as alive, so the handle is returned as still held. A group is
  # gone only when kill(1) reports "No such process". Any other failure,
  # such as a group of another user, keeps it held.

  alias Helyx.Watchdog.Record

  @wait_ms 5_000

  @doc false
  # A new release record, for a handle of `Helyx.Watchdog.start/4`.
  defdelegate record, to: Helyx.Watchdog.Record, as: :new

  @doc false
  # The longest `release/4` of a cancel with the default grace: the grace,
  # the KILL wait of the commands, and the two waits of the watchdogs.
  def max_cancel_ms, do: Helyx.Watchdog.grace_ms() + 3 * @wait_ms

  # The poll interval of a wait for an empty group: no OS event says that a
  # process group is empty.
  @poll_ms 20

  @doc false
  # Options: `:grace_ms`, the TERM grace of a cancel; `:kill`, which runs
  # kill(1), for tests.
  def release(handles, mode, deadline, opts \\ []) do
    kill = until_deadline(deadline, Keyword.get(opts, :kill, &kill_cmd/1))
    grace = Keyword.get(opts, :grace_ms, Helyx.Watchdog.grace_ms())
    # `group > 1` is a deliberate safety lock: `kill -- -1` would signal
    # every process the user may signal. No caller makes such a handle
    # (`parse_marker/2` in `Helyx.Watchdog`, `Port.info(port, :os_pid)`).
    groups =
      for {kind, group, record} = handle <- handles,
          kind in [:command, :watchdog] and is_integer(group) and group > 1 and
            is_reference(record),
          do: handle

    # Copies of a handle carry one record: it is taken once, and they get
    # its one outcome.
    taken =
      groups
      |> Enum.uniq_by(&elem(&1, 2))
      |> Enum.group_by(&Record.take(elem(&1, 2), deadline))

    alive = sweep_taken(Map.get(taken, :taken, []), mode, deadline, grace, kill)
    records = MapSet.new(alive ++ Map.get(taken, :held, []), &elem(&1, 2))
    Enum.filter(groups, &(elem(&1, 2) in records))
  end

  # Releases the groups of the taken handles and returns the handles whose
  # group still has a process. Each record ends gone or not confirmed, also
  # when the release raises.
  defp sweep_taken(taken, mode, deadline, grace, kill) do
    commands = for {:command, _group, _record} = handle <- taken, do: handle
    watchdogs = for {:watchdog, _group, _record} = handle <- taken, do: handle
    # A probe first: a group that stays to the deadline must not keep the
    # handles of groups that are gone already, which the waits would not
    # reach.
    {commands, watchdogs} =
      sweep(alive(commands, kill), alive(watchdogs, kill), mode, deadline, grace, kill)

    alive = commands ++ watchdogs
    Enum.each(alive, &Record.unconfirmed(elem(&1, 2), deadline))
    alive
  catch
    kind, reason ->
      Enum.each(taken, &Record.unconfirmed(elem(&1, 2), deadline))
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp sweep(commands, watchdogs, mode, deadline, grace, kill) do
    left = if mode == :cancel, do: term(commands, within(deadline, grace), kill), else: commands
    {kill_and_wait(left, deadline, kill), sweep_watchdogs(watchdogs, deadline, kill)}
  end

  defp term(commands, until, kill) do
    signal(commands, "TERM", kill)
    poll_gone(commands, until, kill)
  end

  defp sweep_watchdogs(watchdogs, deadline, kill) do
    waiting = poll_gone(watchdogs, within(deadline, @wait_ms), kill)
    kill_and_wait(waiting, deadline, kill)
  end

  defp kill_and_wait(groups, deadline, kill) do
    signal(groups, "KILL", kill)
    poll_gone(groups, within(deadline, @wait_ms), kill)
  end

  defp within(deadline, ms), do: min(System.monotonic_time(:millisecond) + ms, deadline)

  # One kill(1) run signals the whole set.
  defp signal([], _name, _kill), do: :ok

  defp signal(handles, name, kill) do
    kill.(["-#{name}", "--" | Enum.map(handles, &"-#{elem(&1, 1)}")])
    :ok
  end

  # Polls until every group is empty or the monotonic time `until` passes.
  # No sleep passes `until`. Returns the handles whose group still has a
  # process.
  defp poll_gone(groups, until, kill) do
    case alive(groups, kill) do
      [] ->
        []

      alive ->
        left_ms = until - System.monotonic_time(:millisecond)

        if left_ms <= 0 do
          alive
        else
          Process.sleep(min(@poll_ms, left_ms))
          poll_gone(alive, until, kill)
        end
    end
  end

  # The handles whose group still has a process; a group confirmed gone
  # has its record written gone at once.
  defp alive(handles, kill) do
    Enum.reject(handles, fn {_kind, group, record} ->
      gone?(kill.(["-0", "--", "-#{group}"])) and Record.gone(record) == :ok
    end)
  end

  defp gone?({text, status}) when status != 0, do: String.contains?(text, "No such process")
  defp gone?(_alive_or_skipped), do: false

  defp until_deadline(deadline, kill) do
    fn args ->
      if System.monotonic_time(:millisecond) < deadline, do: kill.(args), else: :skipped
    end
  end

  # The C locale keeps the error text of kill(1) in English.
  defp kill_cmd(args),
    do: System.cmd("kill", args, stderr_to_stdout: true, env: [{"LC_ALL", "C"}])
end
