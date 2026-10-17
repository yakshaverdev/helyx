# The check takes its suffix from the test exceptions (`*Message`).
# credo:disable-for-next-line Credo.Check.Consistency.ExceptionNames
defmodule Helyx.HarnessIO.Error do
  @moduledoc false
  # The error result of a program turn that has a text. Core shows an
  # exception as its message, so the user reads `<provider id>: <text>`
  # (docs/features/session-lifecycle.md, "Turn end", step 5). `kind`, the
  # subtype or the status of the result, is for the log only.
  defexception [:provider, :kind, :text]

  @impl true
  def message(%__MODULE__{provider: provider, text: text}), do: provider <> ": " <> text

  # The reason of the result, with its text cut at 2,000 bytes
  # (`HarnessIO.cap_error/1`, which makes a value that is not a string
  # `""`). A result with no text keeps the tuple `{tag, kind, ""}`, and its
  # `inspect` output is the user text.
  def reason(tag, provider, kind, text) do
    case Helyx.HarnessIO.cap_error(text) do
      "" -> {tag, kind, ""}
      text -> %__MODULE__{provider: provider, kind: kind, text: text}
    end
  end
end
