defmodule Helyx.ProviderError do
  @moduledoc false
  # An error of a provider that has a text from its program or its server.
  # Core shows an exception as its message, so the user reads `<provider
  # id>: <text>` (docs/features/session-lifecycle.md, "Turn end", step 5).
  # `kind`, such as the subtype or the status of a result, stays in the
  # reason; the user text and the log do not show it (#756).
  defexception [:provider, :kind, :text]

  @impl true
  def message(%__MODULE__{provider: provider, text: text}), do: provider <> ": " <> text

  # The bound of the text, the bound of a failed start of a program too
  # (`Helyx.Watchdog`), so every error text of a provider has one bound.
  def max_text_bytes, do: Helyx.Watchdog.reason_max_bytes()

  # A value that is not text is empty. The text is cut to valid UTF-8
  # (`Helyx.Text.cap/3`).
  def cap(text) when not is_binary(text), do: ""
  def cap(text), do: Helyx.Text.cap(text, max_text_bytes(), :head)

  # The reason of the error, with its text cut. An error with no text is
  # `empty`, and its `inspect` output is the user text.
  def reason(provider, kind, text, empty) do
    case cap(text) do
      "" -> empty
      text -> %__MODULE__{provider: provider, kind: kind, text: text}
    end
  end
end
