defmodule Helyx.Transport.WebSocket.FrameTest do
  # The decode bounds of one frame, inbound and outbound
  # (docs/features/wire-protocol.md, "Bounds"). The limits at the socket are
  # in web_socket_test.exs.
  use ExUnit.Case, async: true

  import Helyx.Test.WireClient, only: [parts: 1]

  alias Helyx.Transport.WebSocket.Frame

  # 64 MiB of 64-bit words: the heap bound of the refused frames in the wire
  # doc.
  @max_heap_words 8_388_608

  test "25 MiB of nesting is refused with 4400 within the heap bound" do
    assert {:close, 4400} = decode_bounded(String.duplicate("[", 26_214_400))
  end

  test "integers just under the largest BEAM integer are refused with 4400 within the heap bound" do
    # Before the bound, this frame decoded in about 4.4 s.
    integers = Enum.join(List.duplicate(String.duplicate("9", 1_262_592), 20), ",")
    assert {:close, 4400} = decode_bounded(~s({"type":"x","v":[#{integers}]}))
  end

  test "25 MiB of 1,024-digit integers and one over is refused with 4400 within the heap bound" do
    # The decoded integers are on the heap.
    integers = Enum.join(List.duplicate(String.duplicate("9", 1_024), 25_000), ",")
    over = String.duplicate("9", 1_025)
    assert {:close, 4400} = decode_bounded(~s({"type":"x","v":[#{integers},#{over}]}))
  end

  test "a key counts at the start of its object: 32,765 nested objects pass, 32,766 close" do
    # 5 values around the nesting, and 2 for each level, its key with it.
    nested = fn levels ->
      ~s({"type":"x","v":) <>
        String.duplicate(~s({"":), levels) <> "0" <> String.duplicate("}", levels + 1)
    end

    assert {:frame, _} = Frame.decode(nested.(32_765), nil)
    assert {:close, 4400} = Frame.decode(nested.(32_766), nil)
  end

  test "a float out of range closes with 4400" do
    assert {:close, 4400} = Frame.decode(~s({"type":"x","v":1e400}), nil)
    assert {:close, 4400} = Frame.decode(~s({"type":"x","v":-1e400}), nil)
  end

  test "the first of two equal keys wins, as in JSON.decode/1" do
    assert {:frame, %{"type" => "x", "v" => 1}} = Frame.decode(~s({"type":"x","v":1,"v":2}), nil)
  end

  test "the largest answer that Core admits decodes in its frame" do
    # 8,189 zeros: 16,384 bytes of JSON, and 8,206 values in the frame.
    answer = %{"" => List.duplicate(0, 8_189)}
    assert byte_size(JSON.encode!(answer)) == Helyx.Session.max_answer_bytes()
    assert :ok = Helyx.Session.check_answer(answer)
    params = %{"session" => "s", "ask_id" => "a", "answer" => answer}
    frame = %{"type" => "req", "id" => "1", "op" => "answer", "params" => params}
    assert {:frame, ^frame} = Frame.decode(JSON.encode!(frame), nil)
  end

  # 5 values around the zeros: the object, the two keys, "x", and the list.
  # Each decode takes a heap of about 1 GiB (docs/features/tui-attach.md,
  # decision 13).
  @tag :slow
  test "an outbound frame of 38,797,312 values passes, and one value more closes with 4400" do
    zeros = &(~s({"type":"x","v":[) <> String.duplicate("0,", &1 - 1) <> "0]}")
    assert {:frame, %{"v" => v}} = Frame.decode(zeros.(38_797_307), nil, :outbound)
    assert length(v) == 38_797_307
    assert {:close, 4400} = Frame.decode(zeros.(38_797_308), nil, :outbound)
  end

  test "an outbound frame takes more values than an inbound one" do
    frame = JSON.encode!(%{"type" => "x", "v" => List.duplicate(0, 65_536)})
    assert {:close, 4400} = Frame.decode(frame, nil)
    assert {:frame, _frame} = Frame.decode(frame, nil, :outbound)
  end

  # The wire doc states this limit for the JSON decoders of other
  # boundaries, which cite it.
  test "every integer of 1,262,592 digits decodes with JSON.decode/1, and 1,262,593 nines raise" do
    assert {:ok, _} = JSON.decode(String.duplicate("9", 1_262_592))
    assert_raise SystemLimitError, fn -> JSON.decode(String.duplicate("9", 1_262_593)) end
  end

  # The decode of a text joined from parts, as the connection does it, in a
  # process that dies past the heap bound. The text and the joined bytes
  # are off the heap, as in the connection.
  defp decode_bounded(json) do
    parent = self()
    texts = parts(json)

    {pid, ref} =
      :erlang.spawn_opt(
        fn ->
          result =
            Enum.reduce(texts, {:more, nil}, fn text, {:more, p} -> Frame.decode(text, p) end)

          send(parent, {:decoded, self(), result})
        end,
        [:monitor, max_heap_size: %{size: @max_heap_words, kill: true, error_logger: false}]
      )

    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 30_000
    assert reason == :normal
    assert_received {:decoded, ^pid, result}
    result
  end
end
