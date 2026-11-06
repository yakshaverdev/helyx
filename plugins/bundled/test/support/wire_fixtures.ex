defmodule Helyx.Test.WireFixtures do
  @moduledoc false
  # The conformance fixtures of the wire (`test/fixtures/wire/README.md`):
  # the loader, and the match rule of an expected frame.

  @dir Path.expand("../../../../test/fixtures/wire", __DIR__)

  # Fixture file `name`, decoded. Each file names its protocol, so a
  # protocol change fails here until the fixtures follow it.
  def load(name) do
    %{"protocol" => protocol} =
      fixture = @dir |> Path.join(name) |> File.read!() |> JSON.decode!()

    ^protocol = Helyx.Transport.WebSocket.protocol()
    fixture
  end

  # `fixture` when it has every key of `required` and no key outside
  # `required` and `optional`: a misspelt key fails, not skips, its check.
  def keys!(fixture, required, optional) do
    keys = Map.keys(fixture)

    unless Enum.all?(required, &(&1 in keys)) and keys -- (required ++ optional) == [],
      do: raise(ArgumentError, "fixture keys #{inspect(keys)}")

    fixture
  end

  # An expected object matches an object that holds each of its keys with a
  # matching value; a list matches a list of the same length, item by item;
  # any other value matches an equal value.
  def matches?(%{} = expected, %{} = actual),
    do:
      Enum.all?(expected, fn {key, value} ->
        Map.has_key?(actual, key) and matches?(value, actual[key])
      end)

  def matches?(expected, actual) when is_list(expected) and is_list(actual),
    do:
      length(expected) == length(actual) and
        Enum.all?(Enum.zip(expected, actual), fn {e, a} -> matches?(e, a) end)

  def matches?(expected, actual), do: expected === actual
end
