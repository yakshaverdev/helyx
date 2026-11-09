defmodule Helyx.Test.SourceCase do
  @moduledoc false
  # Helpers for the tests of tool sources with `Helyx.Test.Source`.

  import ExUnit.Assertions
  import Helyx.Test.Events
  import Helyx.Test.SessionCase, only: [final_text: 1]

  alias Helyx.Session
  alias Helyx.Test.Source

  # The test process observes the sources of `core`.
  def observe(core) do
    :persistent_term.put({Source, core}, self())
    ExUnit.Callbacks.on_exit(fn -> :persistent_term.erase({Source, core}) end)
  end

  # Runs `fun` in the source process `src` and gives its result.
  def in_source(src, fun) do
    send(src, {:do, self(), fun})
    assert_receive {:done, ^src, result}
    result
  end

  # Announces `group` from `src` and puts `entries` in it.
  def put(src, group, entries) do
    in_source(src, fn ->
      {:ok, [^group]} = Helyx.Tool.announce([group])
      Helyx.Tool.put_tools(group, {:ok, entries})
    end)
  end

  def entry(name, overrides \\ %{}) do
    Map.merge(
      %{name: name, description: "d", parameters: %{"type" => "object"}, exposure: :direct},
      overrides
    )
  end

  # A deferred entry whose spec JSON has about `bytes` bytes.
  def deferred(name, bytes \\ 0) do
    entry(name, %{
      exposure: :deferred,
      parameters: %{"type" => "object", "x" => String.duplicate("p", bytes)}
    })
  end

  def turn_text(session, text \\ "go") do
    :ok = Session.prompt(session, text)
    final_text(collect_until(:turn_end))
  end

  # The next notice event: the session sent it before its reply to the
  # source, but the source's answer to the test is another sender's.
  def notice do
    assert_receive {:helyx_event, %Helyx.Event{type: :notice, data: %{text: text}}}
    text
  end
end
