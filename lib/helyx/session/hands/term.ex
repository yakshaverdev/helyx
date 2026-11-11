defmodule Helyx.Session.Hands.Term do
  @moduledoc false
  # One term of the hands protocol (ADR 0012, `docs/features/remote-hands.md`):
  # a tagged map with a `t`, the kind of the term, and the `instance` of the
  # session. `check/1` is the boundary check that a receiver runs, `encode/1`
  # gives the JSON-ready map, and `decode/1` gives the term back after its
  # check. `fits?/2` is the sender's check of one encoded term against the
  # limits of its direction.
  #
  # The limits are the term limits of ADR 0012 §5. Values counts each scalar,
  # each key, and each container of the encoded map. An integer over
  # `max_integer_chars/0` fails the check, as it would fail the decode of the
  # wire.

  alias Helyx.Message
  alias Helyx.Session.Hands.Term.{Answer, Data, Hands, Session}
  alias Helyx.Session.Hands.Term.Answer.Hands, as: AnswerHands
  alias Helyx.Session.Hands.Term.Hands.Provider, as: HandsProvider
  alias Helyx.Session.Hands.Term.Session.Provider

  @groups [Session, Provider, Hands, HandsProvider, Answer, AnswerHands]

  @kinds Enum.reduce(@groups, %{}, fn group, acc ->
           Enum.reduce(group.kinds(), acc, fn {tag, name}, acc ->
             Map.put(acc, tag, {group, name})
           end)
         end)

  @by_name Map.new(@kinds, fn {tag, {group, name}} -> {name, {group, tag}} end)

  @session_to_hands %{bytes: 26_214_400, values: 65_536}
  @hands_to_session %{bytes: 67_108_864, values: 1_048_576}

  @doc "The limit of one term in `direction`: its joined bytes and its values."
  @spec limit(:session_to_hands | :hands_to_session) :: %{
          bytes: pos_integer(),
          values: pos_integer()
        }
  def limit(:session_to_hands), do: @session_to_hands
  def limit(:hands_to_session), do: @hands_to_session

  @doc "The integer limit of one term, in decimal characters."
  defdelegate max_integer_chars(), to: Data

  @doc "The byte bound of a protocol id."
  defdelegate max_id_bytes(), to: Data

  @doc "The byte bound of a registration id that is a module name."
  defdelegate max_plugin_bytes(), to: Data

  @doc "The most paths of a read of the folder, and the byte bound of one path."
  defdelegate max_paths(), to: Data
  defdelegate max_path_bytes(), to: Data

  @doc "The kind of each term, as its `t` atom."
  @spec kinds() :: [atom()]
  def kinds, do: Map.keys(@kinds)

  @doc "The direction of a term of kind `tag`."
  @spec direction(atom()) :: :session_to_hands | :hands_to_session | nil
  def direction(tag) do
    case Map.fetch(@kinds, tag) do
      {:ok, {group, _name}} -> group.direction(tag)
      :error -> nil
    end
  end

  @doc "The boundary check of a term: `{:ok, checked}` or `:error`."
  @spec check(term()) :: {:ok, term()} | :error
  def check(%{t: tag} = term) do
    with {:ok, {group, _name}} <- Map.fetch(@kinds, tag),
         {:ok, checked, _map, _size} <- encoded(term, group) do
      {:ok, checked}
    end
  end

  def check(_term), do: :error

  @doc "The JSON-ready map of a term, or `:error` for a term that fails its check."
  @spec encode(term()) :: {:ok, map()} | :error
  def encode(%{t: tag} = term) do
    with {:ok, {group, _name}} <- Map.fetch(@kinds, tag),
         {:ok, _checked, map, _size} <- encoded(term, group) do
      {:ok, map}
    end
  end

  def encode(_term), do: :error

  @doc "The term of an encoded map, after its check."
  @spec decode(term()) :: {:ok, term()} | :error
  def decode(%{"t" => name} = map) do
    with {:ok, {group, _tag}} <- Map.fetch(@by_name, name),
         {:ok, term} <- group.decode(map) do
      check(term)
    end
  end

  def decode(_map), do: :error

  @doc """
  Whether one encoded term fits the limits of `direction`: its joined bytes
  and its values, and a term of that direction.
  """
  @spec fits?(term(), :session_to_hands | :hands_to_session) :: :ok | :error
  def fits?(%{t: tag} = term, direction) do
    with true <- direction(tag) == direction,
         {:ok, {group, _name}} <- Map.fetch(@kinds, tag),
         {:ok, _checked, map, size} <- encoded(term, group) do
      limit = limit(direction)

      if size <= limit.bytes and values(map) <= limit.values, do: :ok, else: :error
    else
      _ -> :error
    end
  end

  def fits?(_term, _direction), do: :error

  @doc false
  # The values of an encoded term: each scalar, each key, and each container.
  @spec values(term()) :: pos_integer()
  def values(value) when is_map(value) do
    1 + Enum.reduce(value, 0, fn {key, item}, sum -> sum + 1 + values(key) + values(item) end)
  end

  def values(value) when is_list(value), do: 1 + Enum.reduce(value, 0, &(values(&1) + &2))
  def values(_scalar), do: 1

  defp encoded(term, group) do
    with {:ok, checked} <- group.check(term),
         {:ok, map} <- group.encode(checked),
         {:ok, size} <- Message.encoded_size(map) do
      {:ok, checked, map, size}
    end
  end
end
