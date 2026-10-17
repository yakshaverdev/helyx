defmodule Helyx.Session.HistoryTest do
  # The cut of a tail snapshot and of a history page
  # (docs/features/session-snapshot.md, "Cut", #658).
  use ExUnit.Case, async: true

  alias Helyx.Message
  alias Helyx.Session.History

  @max_bytes 16 * 1024 * 1024

  defp user(id, text \\ "u"), do: %{Message.user(text) | id: id}

  defp assistant(id, calls),
    do: %Message{id: id, role: :assistant, content: Enum.map(calls, &call/1)}

  defp call(id), do: %Message.ToolCall{id: id, name: "read", arguments: %{}}

  defp result(id, call_id, text \\ "r"),
    do: %{Message.tool_result(call(call_id), {:ok, text}) | id: id}

  defp ids(%{messages: messages}), do: Enum.map(messages, & &1.id)

  # u1 a1(c1, c2) r1 r2 u2 a2
  defp transcript do
    [user("u1"), assistant("a1", ["c1", "c2"]), result("r1", "c1"), result("r2", "c2")] ++
      [user("u2"), assistant("a2", [])]
  end

  defp tail(opts) do
    with {:ok, tail, nil} <- History.subscribe(opts), do: {:ok, tail}
  end

  test "the option lists: none, or one count from 1 to 1,000" do
    assert tail([]) == {:ok, nil}
    assert History.limit([]) == {:ok, 200}

    for {check, key} <- [{&tail/1, :tail}, {&History.limit/1, :limit}] do
      assert check.([{key, 1}]) == {:ok, 1}
      assert check.([{key, 999}]) == {:ok, 999}
      assert check.([{key, 1_000}]) == {:ok, 1_000}

      for bad <-
            [[{key, 0}], [{key, 1_001}], [{key, 1.0}], [{key, "5"}], [{key, nil}]] ++
              [[{key, 5}, {key, 5}], [{key, 5}, other: 1], [other: 1], %{key => 5}] do
        assert check.(bad) == {:error, :invalid_limit}
      end
    end
  end

  test "the subscribe options: after is an instance id and a seq >= 0, at most once" do
    assert History.subscribe(after: {"i", 0}) == {:ok, nil, {"i", 0}}
    assert History.subscribe(tail: 5, after: {"i", 7}) == {:ok, 5, {"i", 7}}
    assert History.subscribe(after: {"i", 7}, tail: 5) == {:ok, 5, {"i", 7}}

    for bad <- [{"i", -1}, {"i", 1.0}, {:i, 1}, {"i"}, "i", nil] do
      assert History.subscribe(after: bad) == {:error, :invalid_after}
    end

    assert History.subscribe(after: {"i", 1}, after: {"i", 1}) == {:error, :invalid_after}
    assert History.subscribe(tail: 0, after: {"i", 1}) == {:error, :invalid_limit}

    for improper <- [[{:tail, 5} | :bad], [{:after, {"i", 1}} | :bad]] do
      assert History.subscribe(improper) == {:error, :invalid_limit}
    end
  end

  test "the tail takes the newest messages up to the count" do
    assert History.cut(transcript(), 6) == %{messages: transcript(), more: false}
    assert History.cut(transcript(), 1_000) == %{messages: transcript(), more: false}
    assert ids(History.cut(transcript(), 2)) == ["u2", "a2"]
    assert History.cut(transcript(), 2).more
    assert ids(History.cut(transcript(), 1)) == ["a2"]
  end

  test "the cut moves to newer messages until it is at a user or an assistant message" do
    # Four would start at r1, three at r2: both move to u2.
    assert History.cut(transcript(), 4) == %{messages: Enum.take(transcript(), -2), more: true}
    assert History.cut(transcript(), 3) == %{messages: Enum.take(transcript(), -2), more: true}
    assert ids(History.cut(transcript(), 5)) == ["a1", "r1", "r2", "u2", "a2"]
  end

  test "a cut that leaves no message gives the newest group alone, whatever its count" do
    group = [assistant("a1", ["c1", "c2"]), result("r1", "c1"), result("r2", "c2")]
    messages = [user("u1") | group]

    assert History.cut(messages, 1) == %{messages: group, more: true}
    assert History.cut(messages, 2) == %{messages: group, more: true}
    assert History.cut(group, 1) == %{messages: group, more: false}
  end

  test "an empty transcript is an empty page" do
    assert History.cut([], 200) == %{messages: [], more: false}
  end

  describe "the bytes of the tail" do
    # A user message of `size` bytes by `:erlang.external_size/1`; the size
    # grows by one with each byte of its text, also at these sizes.
    defp sized(id, size) do
      base = :erlang.external_size(user(id, ""))
      message = user(id, :binary.copy("x", size - base))
      assert :erlang.external_size(message) == size
      message
    end

    test "at the limit both messages go, one byte over only the newest" do
      half = div(@max_bytes, 2)
      assert ids(History.cut([sized("o", half), sized("n", half)], 10)) == ["o", "n"]
      assert ids(History.cut([sized("o", half - 1), sized("n", half)], 10)) == ["o", "n"]
      assert ids(History.cut([sized("o", half + 1), sized("n", half)], 10)) == ["n"]
      assert History.cut([sized("o", half + 1), sized("n", half)], 10).more
    end

    test "a newest message over the limit goes alone, and its content is whole" do
      big = sized("n", @max_bytes + 1)
      assert History.cut([user("o"), big], 10) == %{messages: [big], more: true}

      assert History.cut([sized("n", @max_bytes)], 10) == %{
               messages: [sized("n", @max_bytes)],
               more: false
             }
    end

    test "a group over the limit goes whole: an assistant message and its large results" do
      results = for n <- 1..3, do: result("r#{n}", "c#{n}", :binary.copy("é", div(@max_bytes, 4)))
      group = [assistant("a", ["c1", "c2", "c3"]) | results]
      assert History.cut([user("u") | group], 1_000) == %{messages: group, more: true}
    end
  end

  describe "a page" do
    test "the messages before `before`, with the cut, and the next cursor" do
      assert History.page(transcript(), "a2", 1) ==
               {:ok, %{messages: [user("u2")], more: true, next: "u2"}}

      # Two before u2 start at r2: the cut gives the group of a1.
      assert {:ok, %{messages: messages, more: true, next: "a1"}} =
               History.page(transcript(), "u2", 2)

      assert Enum.map(messages, & &1.id) == ["a1", "r1", "r2"]

      assert History.page(transcript(), "a1", 200) ==
               {:ok, %{messages: [user("u1")], more: false, next: nil}}

      assert History.page(transcript(), "u1", 200) ==
               {:ok, %{messages: [], more: false, next: nil}}
    end

    test "the pages from the tail to the oldest give every message once, in order" do
      %{messages: [first | _] = tail, more: true} = History.cut(transcript(), 1)

      pages =
        Stream.unfold(first.id, fn
          nil ->
            nil

          before ->
            with {:ok, page} <- History.page(transcript(), before, 1), do: {page, page.next}
        end)

      assert Enum.flat_map(Enum.reverse(Enum.to_list(pages)), & &1.messages) ++ tail ==
               transcript()
    end

    test "an id that no message has is :unknown_message" do
      assert History.page(transcript(), "nope", 10) == {:error, :unknown_message}
      assert History.page([], "u1", 10) == {:error, :unknown_message}
    end
  end
end
