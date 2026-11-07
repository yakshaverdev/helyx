defmodule Helyx.Hook.Command.RelayTest do
  # The relay of `Helyx.Hook.Command`: what it reads, its signals, and its
  # frames (docs/features/command-hook.md), run in fake hands.
  use ExUnit.Case, async: true

  alias Helyx.Hook.Command
  alias Helyx.Hook.Command.{Answer, Error, Run}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Helyx.Test.Hands.fake(self())

    input = %{
      tool: "bash",
      arguments: %{"command" => "ls é"},
      cwd: dir,
      session_id: "s1",
      turn_id: "t1",
      call_id: "c1",
      provider: nil
    }

    %{input: input, after: Map.put(input, :result, {:ok, "out"})}
  end

  defp env(point, command), do: [{point, [command: command]}]

  defp before(input, command), do: Command.run(:before_tool, input, env(:before_tool, command))

  defp failure(fun) do
    error = assert_raise Error, fun
    error.message
  end

  describe "the answer is what the command wrote before it exited" do
    test "what a child writes after the exit is not read", %{input: input} do
      late = ~S|(sleep 0.3; printf '{"decision":"block","reason":"late"}') &|
      assert before(input, "#{late} exit 0") == :allow
      assert before(input, "#{late} echo early >&2; exit 2") == {:deny, "early\n"}
    end
  end

  describe "the relay's signals" do
    test "a HUP to the group reaches the command and not the relay", %{input: input} do
      # A relay that did not ignore the HUP would die of it: status 129.
      command = "trap 'echo hup >&2; exit 2' HUP; kill -HUP 0; sleep 5"
      assert before(input, command) == {:deny, "hup\n"}
    end

    # The relay started with `signal` pending and blocked, as when it comes
    # to the group between the relay's block and its fork: the relay sends
    # it on to the command, which dies of it before its `sleep` ends.
    for {signal, status} <- [{"TERM", 143}, {"HUP", 129}] do
      test "a #{signal} pending at the fork is sent on to the command" do
        relay = File.read!(Path.expand("../../../../lib/helyx/hook/command/relay.pl", __DIR__))
        pending = "use POSIX; sigprocmask(SIG_BLOCK, POSIX::SigSet->new(SIG#{unquote(signal)}));"

        port =
          Port.open({:spawn_executable, System.find_executable("perl")}, [
            :binary,
            :exit_status,
            args:
              ["-e", pending <> " kill #{unquote(signal)} => $$; exec @ARGV", "perl"] ++
                ["-e", relay, "--", "65536", "bash", "-c", "sleep 5; echo ran"]
          ])

        assert Run.collect(port, %Run.Out{}) == {:exit, unquote(status), "", false, ""}
      end
    end

    test "a TERM to the group reaches the command and not the relay", %{input: input} do
      command = "trap 'echo term >&2; exit 2' TERM; kill -TERM 0; sleep 5"
      assert before(input, command) == {:deny, "term\n"}
    end
  end

  describe "the frames of the relay" do
    defp frame(tag, data), do: <<tag, byte_size(data)::32, data::binary>>

    test "whole frames are taken, and a part waits for the next read" do
      {:ok, out} =
        Run.frames(
          frame(?o, "ab") <> frame(?e, "c") <> binary_part(frame(?o, "de"), 0, 3),
          %Run.Out{}
        )

      assert %Run.Out{stdout: "ab", stderr: "c", buffer: <<?o, 0, 0>>} = out
      {:ok, out} = Run.frames(out.buffer <> binary_part(frame(?o, "de"), 3, 4), out)
      assert %Run.Out{stdout: "abde", buffer: ""} = out
    end

    test "a frame at the size limit is taken, one byte over is no frame" do
      max = Run.max_frame_bytes()
      data = String.duplicate("é", div(max, 2))
      assert {:ok, %Run.Out{stdout: ^data}} = Run.frames(frame(?o, data), %Run.Out{})
      assert Run.frames(frame(?o, data <> "a"), %Run.Out{}) == :error
    end

    test "another tag is no frame, in a whole head and in a part" do
      assert Run.frames(frame(?x, "a"), %Run.Out{}) == :error
      assert Run.frames("c", %Run.Out{}) == :error
    end

    # A port that writes `text` and exits 0, read as the relay's stream.
    defp read(text) do
      port =
        Port.open({:spawn_executable, "/bin/sh"}, [
          :binary,
          :exit_status,
          args: ["-c", ~S(printf "$0"), text]
        ])

      Run.collect(port, %Run.Out{})
    end

    test "a stream that is not frames, or ends in a part of one, is a failed hook",
         %{input: input} do
      assert {:exit, 0, "ab", false, ""} = read(~S(o\0\0\0\002ab))

      for text <- ["not a frame", ~S(o\0\0\0\005ab), ~S(o\0\001\0\001a)] do
        assert read(text) == :unreadable
      end

      assert failure(fn -> Answer.of(:unreadable, :before_tool, input) end) ==
               "the output of the command could not be read"
    end
  end
end
