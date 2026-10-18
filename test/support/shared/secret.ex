defmodule Helyx.Test.Secret do
  @moduledoc false
  # The check that a text holds no printed form of a token of the
  # transport or of its key (docs/agents/review-checklist.md, a secret in
  # data that a dependency can log).

  import ExUnit.Assertions

  # The token, and the key as bytes, as Elixir and Erlang print them, and in
  # base16 and base64.
  def refute_secret(text, token) do
    key = :crypto.hash(:sha256, token)

    for form <- [
          token,
          key,
          inspect(key, limit: :infinity),
          inspect(key, binaries: :as_strings),
          IO.chardata_to_string(:io_lib.format(~c"~w", [key])),
          Base.encode16(key),
          Base.encode16(key, case: :lower),
          Base.encode64(key)
        ] do
      refute String.contains?(text, form), "the log holds a form of the token or the key"
    end
  end
end
