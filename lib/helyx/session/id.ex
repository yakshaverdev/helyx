defmodule Helyx.Session.Id do
  @moduledoc false
  # One id scheme for sessions, session instances, turns, and session file entries.

  @doc "A short random id, URL and filename safe."
  @spec new() :: String.t()
  def new, do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
end
