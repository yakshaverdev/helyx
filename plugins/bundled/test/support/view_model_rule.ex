defmodule Helyx.Test.ViewModelRule do
  @moduledoc false
  # The rule of ADR 0006 section 3 for tests: a client that joins with a
  # snapshot shows the view model of a client that watched from the start,
  # except for notices and the partial reply of an aborted or failed turn.
  # These are not in the transcript, so `transcript/1` leaves them out of
  # the view model of the client that watched. A snapshot never holds them;
  # a test compares its view model with no `transcript/1`.

  alias Helyx.Message
  alias Helyx.TUI.ViewModel

  @doc "The view model without the cells that a snapshot cannot show."
  def transcript(vm), do: %{vm | cells: Enum.reject(vm.cells, &display_only?/1)}

  defp display_only?({:notice, _}), do: true

  defp display_only?(%Message{role: :assistant, stop_reason: stop}),
    do: stop in [:error, :aborted]

  defp display_only?(_cell), do: false

  @doc "Folds the events into the view model."
  def fold(vm, events), do: Enum.reduce(events, vm, &ViewModel.apply(&2, &1))
end
