defmodule Helyx.TUI.Guard do
  @moduledoc false
  # The recompile hook of ADR 0005 for a file that ex_ratatui guards. A
  # product can add or remove ex_ratatui after its first build, and Mix does
  # not see that as a reason to compile the file again. Two parts make it do
  # so, and both are necessary (measurements in ADR 0005). The module that
  # uses this always exists and lives in the guarded file, because Mix reaches
  # a stale source only through a module the source defines.
  # `__mix_recompile__?/0` tells Mix on every compile whether the answer
  # changed. This module needs nothing from ex_ratatui, so it has no guard.

  defmacro __using__(_opts) do
    quote do
      @available Code.ensure_loaded?(ExRatatui.App)

      @spec available?() :: boolean()
      def available?, do: @available

      @spec __mix_recompile__?() :: boolean()
      def __mix_recompile__?, do: Code.ensure_loaded?(ExRatatui.App) != @available
    end
  end
end
