defmodule Helyx.Session.Id do
  @moduledoc false
  # One id scheme for sessions, session instances, turns, messages, and
  # session file entries.

  @doc "A short random id, URL and filename safe."
  @spec new() :: String.t()
  def new, do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

  @doc "Whether `id` has the format of `new/0`: 12 URL-safe characters."
  @spec valid?(term()) :: boolean()
  def valid?(id), do: is_binary(id) and id =~ ~r/\A[A-Za-z0-9_-]{12}\z/
end
