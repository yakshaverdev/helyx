defmodule Helyx.Session.Id do
  @moduledoc false
  # One id scheme for sessions, session instances, turns, messages, asks,
  # and session file entries.

  @doc "A short random id, URL and filename safe."
  @spec new() :: String.t()
  def new, do: encode(:crypto.strong_rand_bytes(9))

  @doc """
  The id of the session with the parent link of `session_id` and
  `call_id`: derived from the link, so a client finds a child from the call
  alone. A session id has a fixed length, so the two join with no mark.
  """
  @spec child(String.t(), String.t()) :: String.t()
  def child(session_id, call_id),
    do: encode(binary_part(:crypto.hash(:sha256, session_id <> call_id), 0, 9))

  defp encode(bytes), do: Base.url_encode64(bytes, padding: false)

  @doc "Whether `id` has the format of `new/0`: 12 URL-safe characters."
  @spec valid?(term()) :: boolean()
  def valid?(id), do: is_binary(id) and id =~ ~r/\A[A-Za-z0-9_-]{12}\z/
end
