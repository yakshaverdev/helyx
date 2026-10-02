defmodule Helyx.WatchdogTest do
  # Direct tests of the perl watchdog through the launcher, without the
  # hands: the marker and go-ahead protocol, the status passthrough, and the
  # kill on a closed port.
  use ExUnit.Case, async: true

  import Helyx.Test.OSHelpers

  defp open(command, bash \\ "bash", feed \\ -1) do
    {exe, options} = Helyx.Watchdog.launcher([bash, "-c", command], File.cwd!(), "nonce", feed)
    Port.open({:spawn_executable, exe}, options)
  end

  defp read_marker(port) do
    receive do
      {^port, {:data, data}} ->
        ["nonce " <> group, rest] = String.split(data, "\n", parts: 2)
        {String.to_integer(group), rest}
    after
      Helyx.Test.Events.wait_ms() -> flunk("no group marker")
    end
  end

  # Gives the go-ahead and reads up to `text`, which starts with the start
  # line. Returns what came after it.
  defp go(port, acc, text \\ "nonce 1\n") do
    true = Port.command(port, "go\n")
    await(port, acc, text)
  end

  defp await(port, acc, text) do
    case String.split(acc, text, parts: 2) do
      ["", rest] ->
        rest

      _ ->
        receive do
          {^port, {:data, data}} -> await(port, acc <> data, text)
        after
          Helyx.Test.Events.wait_ms() -> flunk("no #{inspect(text)}; got #{inspect(acc)}")
        end
    end
  end

  defp collect(port, acc) do
    receive do
      {^port, {:data, data}} -> collect(port, acc <> data)
      {^port, {:exit_status, status}} -> {acc, status}
    after
      Helyx.Test.Events.wait_ms() -> flunk("no exit status; got #{inspect(acc)}")
    end
  end

  test "the command ends first: output and exit status pass through" do
    port = open("echo out; echo err >&2; exit 3")
    {group, rest} = read_marker(port)
    assert group > 1
    assert {"out\nerr\n", 3} = collect(port, go(port, rest))
  end

  test "a signal death is reported as 128 plus the signal" do
    port = open("kill -TERM $$")
    {_group, rest} = read_marker(port)
    assert {_out, 143} = collect(port, go(port, rest))
  end

  test "stdin ends first: the group is killed" do
    port = open("echo ready; sleep 30")
    {group, ""} = read_marker(port)
    assert "" = go(port, "", "nonce 1\nready\n")

    Port.close(port)
    assert group_gone_within?(group)
  end

  test "a command that ignores TERM is killed after the grace period" do
    port = open("trap '' TERM; echo ready; sleep 30")
    {group, ""} = read_marker(port)
    assert "" = go(port, "", "nonce 1\nready\n")

    Port.close(port)
    assert group_gone_within?(group)
  end

  # The check at 1 s, past the default grace of 500 ms, leaves 9 s of the
  # grace as the margin for load: in a full run with the slow tier, a check
  # at 1 s ran after the end of a 2 s grace (2026-10-02). The KILL then comes
  # 10 s after the close, and the wait for it ends 21 s or more after the
  # close, 39 s before the command ends by itself.
  @load_grace_ms 10_000

  @tag :slow
  test "a longer grace holds the KILL until its limit" do
    argv = ["bash", "-c", "trap '' TERM; echo ready; sleep 60"]
    {exe, options} = Helyx.Watchdog.launcher(argv, File.cwd!(), "nonce", -1, @load_grace_ms)
    port = Port.open({:spawn_executable, exe}, options)
    {group, ""} = read_marker(port)
    assert "" = go(port, "", "nonce 1\nready\n")

    Port.close(port)
    Process.sleep(1_000)
    assert os_alive?("-#{group}")
    assert group_gone_within?(group, 20_000)
  end

  test "a failed exec: the start line, then the report under the go-ahead word (issue #70)" do
    port = open("echo ran", "/nonexistent/bash")
    {_group, rest} = read_marker(port)

    assert {"cannot run /nonexistent/bash: No such file or directory\n", 0} =
             collect(port, go(port, rest, "nonce 1\ngo 0\n"))
  end

  test "a held child that is stopped does not hold the kill on a closed port (issue #70)" do
    port = open("echo ran")
    {group, ""} = read_marker(port)
    {_, 0} = signal_group("STOP", group)
    true = Port.command(port, "go\n")

    Port.close(port)
    assert group_gone_within?(group)
  end

  @tag :tmp_dir
  test "without the go-ahead the command never runs", %{tmp_dir: dir} do
    ran = Path.join(dir, "ran")
    port = open("touch #{ran}")
    {group, ""} = read_marker(port)

    Port.close(port)
    assert group_gone_within?(group)
    refute File.exists?(ran)
  end

  # A cwd that is not text makes `Port.open` raise `ArgumentError`. Like
  # `SystemLimitError` at the port limit, it has no `:original` field.
  test "a spawn that raises a normalized error returns a result that names perl" do
    assert {:failed, "perl did not start: " <> reason} =
             Helyx.Watchdog.start(["true"], 123, nil)

    # The spawn ran: a failed perl lookup would pass the match above.
    refute reason == "not found on PATH"
  end

  describe "input (#10)" do
    test "open input: a command that does not read cannot stop the kill on a closed port" do
      port = open("echo ready; sleep 30", "bash", -2)
      {group, ""} = read_marker(port)
      true = Port.command(port, ["go\n", :binary.copy("x", 1_000_000)])
      assert "" = await(port, "", "nonce 1\nready\n")

      Port.close(port)
      assert group_gone_within?(group)
    end

    test "open input: a command that closes its stdin early does not end the watchdog" do
      port = open("exec 0<&-; sleep 0.2; echo still", "bash", -2)
      {_group, rest} = read_marker(port)
      true = Port.command(port, ["go\n", :binary.copy("x", 1_000_000)])
      assert {"nonce 1\nstill\n", 0} = collect(port, rest)
    end

    test "open input: parts arrive until a NUL byte, then the command reads end of file" do
      argv = ["bash", "-c", "cat; echo done"]
      assert {:started, port, "", nonce, _go} = Helyx.Watchdog.start(argv, File.cwd!(), :open)
      Helyx.Watchdog.write(port, "one\n")
      assert "" = await(port, "", "#{nonce} 1\none\n")
      Helyx.Watchdog.write(port, ["two\n", <<0>>, "dropped\n"])
      assert {"two\ndone\n", 0} = collect(port, "")
    end

    test "open input: a closed port kills the group, with the input still open" do
      port = open("cat; sleep 30", "bash", -2)
      {group, rest} = read_marker(port)
      true = Port.command(port, "go\nready\n")
      assert "" = await(port, rest, "nonce 1\nready\n")

      Port.close(port)
      assert group_gone_within?(group)
    end

    test "open input: a command that does not read is stopped over the stdin cap (#196)" do
      # The watchdog can exit while a part of the write still waits in the
      # port: the port then closes with `:epipe` and sends no exit status.
      Process.flag(:trap_exit, true)
      port = open("echo ready; sleep 30", "bash", -2)
      {group, rest} = read_marker(port)
      true = Port.command(port, "go\nready\n")
      assert "" = await(port, rest, "nonce 1\nready\n")

      # The pipe takes some bytes; the watchdog's buffer takes the rest.
      true = Port.command(port, :binary.copy("x", 2 * Helyx.Watchdog.stdin_max_bytes()))

      receive do
        {^port, {:exit_status, status}} -> assert status == 143
        {:EXIT, ^port, reason} -> assert reason == :epipe
      after
        Helyx.Test.Events.wait_ms() -> flunk("the watchdog did not stop the command")
      end

      assert group_gone_within?(group)
    end

    # A command that does not read gets the cap in the watchdog plus what the
    # pipe holds: at most 65,536 bytes (macOS and Linux), and on macOS as
    # little as 512 bytes when the pipe memory of the system is short. So the
    # cap alone is never over it, and the cap plus 65,537 bytes always is.
    # Each byte counts, a byte of a multibyte character too.
    for {over, stopped?} <- [{0, false}, {65_537, true}], text <- ["x", "é"] do
      test "open input: the stdin cap and #{over} bytes, #{inspect(text)} (#196)" do
        Process.flag(:trap_exit, true)
        port = open("echo ready; exec sleep 30", "bash", -2)
        {group, rest} = read_marker(port)
        true = Port.command(port, "go\n")
        assert "" = await(port, rest, "nonce 1\nready\n")

        size = Helyx.Watchdog.stdin_max_bytes() + unquote(over)
        input = :binary.part(:binary.copy(unquote(text), size), 0, size)
        true = Port.command(port, input)

        if unquote(stopped?) do
          receive do
            {^port, {:exit_status, status}} -> assert status == 143
            {:EXIT, ^port, reason} -> assert reason == :epipe
          after
            Helyx.Test.Events.wait_ms() -> flunk("the watchdog did not stop the command")
          end

          assert group_gone_within?(group)
        else
          refute_receive {^port, {:exit_status, _}}, 500
          refute_received {:EXIT, ^port, _}
          assert os_alive?("-#{group}")
          Port.close(port)
          assert group_gone_within?(group)
        end
      end
    end

    test "open input: the cap counts the bytes not read yet, not all bytes (#196)" do
      port = open("cat", "bash", -2)
      {_group, rest} = read_marker(port)
      true = Port.command(port, "go\n")
      assert "" = await(port, rest, "nonce 1\n")
      part = :binary.copy("x", div(Helyx.Watchdog.stdin_max_bytes(), 2))

      for _ <- 1..3 do
        true = Port.command(port, part)
        await_bytes(port, byte_size(part))
      end

      true = Port.command(port, <<0>>)
      assert {"", 0} = collect(port, "")
    end

    # Reads exactly `n` bytes of output, in linear time. `cat` echoes only
    # what it read, so the whole part has left the watchdog.
    defp await_bytes(_port, 0), do: :ok

    defp await_bytes(port, n) do
      receive do
        {^port, {:data, data}} when byte_size(data) <= n -> await_bytes(port, n - byte_size(data))
      after
        Helyx.Test.Events.wait_ms() -> flunk("#{n} bytes of output did not arrive")
      end
    end
  end

  describe "the preamble limit of the marker read (issue #52)" do
    # A ref stands for the port. Only a buffer that ends inside a line under
    # the limit waits for a message.
    defp marker(buffer), do: Helyx.Watchdog.read_marker(make_ref(), "N", "", buffer)

    # The marker line "N 4242\n" is 7 bytes, so it ends at byte 4096, the
    # limit, after 4089 bytes of noise with the newline.
    test "a marker line that ends at the limit or under it is found" do
      for size <- [4087, 4088] do
        noise = String.duplicate("x", size)
        assert marker(noise <> "\nN 4242\nout") == {4242, noise <> "\nout"}
      end
    end

    test "multibyte noise counts in bytes" do
      noise = String.duplicate("é", 2043) <> "xx"
      assert byte_size(noise) == 4088
      assert marker(noise <> "\nN 4242\nout") == {4242, noise <> "\nout"}
      over = "é" <> noise
      assert marker(over <> "\nN 4242\n") == {:no_marker, over <> "\nN 4242\n"}
    end

    test "a marker line that ends over the limit ends the search" do
      for marker <- ["N 4242", "N 0"], over <- [1, 2, 100] do
        # The marker line ends `over` bytes past the limit.
        size = 4096 - byte_size(marker) - 2 + over
        buffer = String.duplicate("x", size) <> "\n#{marker}\nout"
        assert marker(buffer) == {:no_marker, buffer}
      end
    end

    test "the limit counts all noise lines together" do
      # 40 lines of 100 bytes with the newline are 4000 bytes read past.
      lines = String.duplicate(String.duplicate("x", 99) <> "\n", 40)
      at = lines <> String.duplicate("y", 88)
      assert marker(at <> "\nN 4242\n") == {4242, at <> "\n"}
      over = lines <> String.duplicate("y", 89) <> "\nN 4242\n"
      assert marker(over) == {:no_marker, over}
    end

    test "the answer does not depend on how the stream is cut into messages" do
      for {size, expected} <- [{4088, &{4242, &1}}, {4089, &{:no_marker, &1 <> "N 4242\n"}}] do
        port = make_ref()
        noise = String.duplicate("x", size) <> "\n"
        send(self(), {port, {:data, "N 42"}})
        send(self(), {port, {:data, "42\n"}})
        assert Helyx.Watchdog.read_marker(port, "N", "", noise) == expected.(noise)
      end
    end

    test "a partial line at the limit ends the search without a wait" do
      buffer = String.duplicate("x", 4096)
      assert marker(buffer) == {:no_marker, buffer}
    end

    test "a partial line under the limit waits; an exit then is no marker" do
      port = make_ref()
      send(self(), {port, {:exit_status, 2}})
      buffer = String.duplicate("x", 4095)
      assert Helyx.Watchdog.read_marker(port, "N", "", buffer) == {:no_marker, buffer}
    end

    test "the not-started marker is found after noise" do
      assert marker("perl: warning\nN 0\nwhy") == {:not_started, "perl: warning\nwhy"}
    end

    test "a line without the nonce is never a marker" do
      for forged <- ["4242", "0", "M 4242", "N 4242 1", "N  4242", " N 4242", "N 1", "N -5"] do
        assert marker("#{forged}\nN 77\n") == {77, "#{forged}\n"}
      end
    end
  end
end
