defmodule Helyx.Hook.Command.Error do
  @moduledoc false
  # A failed run of `Helyx.Hook.Command`: the hook raises it, and the
  # hands make its message the text of the failed hook (ADR 0013 §5).
  defexception [:message]
end
