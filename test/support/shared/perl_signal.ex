defmodule Helyx.Test.PerlSignal do
  @moduledoc false
  # Signals to the perl process that holds a lock (`Helyx.Session.Lock`),
  # and to no other process. `kill` with the pid 0 or a negative pid signals
  # a process group, among them the group of the test VM, and so of
  # `mix precommit`. A port that the forker of the VM has not started yet
  # reports the os pid 0 (OTP 28 `sys_drivers.c`: `spawn_start` creates the
  # port with the pid 0, set when `erl_child_setup` answers), and a
  # `kill -STOP 0` from a test froze a precommit run (#833). So each send
  # checks that the pid is an integer over 1, and that `ps` shows a perl
  # whose arguments end with the lock path `lock_path`; else the test fails
  # and nothing is sent. A pid that ends and is reused between the check
  # and the `kill` is not covered: any check before a `kill` has that gap.

  import ExUnit.Assertions

  alias Helyx.Test.Events

  # The os pid of the perl process of `port`, which holds `lock_path`. It
  # waits until the port reports its pid.
  def pid(port, lock_path) do
    Events.wait_until(
      fn -> match?({:os_pid, n} when is_integer(n) and n > 1, Port.info(port, :os_pid)) end,
      Events.wait_ms(),
      "the port to report the os pid of its perl"
    )

    {:os_pid, pid} = Port.info(port, :os_pid)
    assert perl?(pid, lock_path), "the os pid #{pid} is not the perl of #{lock_path}"
    pid
  end

  # Sends `signal`, such as "STOP", "CONT", or "KILL", to the perl `pid`
  # that holds `lock_path`.
  def send!(pid, signal, lock_path) when is_integer(pid) and pid > 1 do
    assert perl?(pid, lock_path), "the os pid #{pid} is not the perl of #{lock_path}"
    {_, 0} = System.cmd("kill", ["-" <> signal, Integer.to_string(pid)])
    :ok
  end

  # A continue for an `on_exit`: a stopped perl never reads the end of its
  # stdin, so after a failure it would outlive the run. Nothing is sent
  # when `pid` is no longer that perl.
  def continue(pid, lock_path) when is_integer(pid) and pid > 1 do
    if perl?(pid, lock_path),
      do: System.cmd("kill", ["-CONT", Integer.to_string(pid)], stderr_to_stdout: true)

    :ok
  end

  # The arguments of the perl of a lock end with its lock path; the check
  # takes the word `perl` and that end. `-ww` gives the whole line.
  defp perl?(pid, lock_path) do
    case System.cmd("ps", ["-ww", "-o", "args=", "-p", Integer.to_string(pid)],
           stderr_to_stdout: true
         ) do
      {args, 0} ->
        String.contains?(args, "perl") and String.ends_with?(String.trim(args), " " <> lock_path)

      _gone ->
        false
    end
  end
end
