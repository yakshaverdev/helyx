defmodule Helyx.TUI.Quit do
  @moduledoc false
  # The double Ctrl+C of the TUI (#486, docs/features/coding-agent.md,
  # "TUI"): a first Ctrl+C clears the composer and arms the quit for
  # @window_ms; a second one while armed quits.

  alias ExRatatui.Event.{Key, Paste}

  @window_ms 500

  # nil while disarmed, or the ref of the armed window and whether the
  # composer was empty when it was armed. The footer shows the hint only
  # while that flag holds and the composer is still empty.
  @type t :: nil | {reference(), armed_on_empty? :: boolean()}

  # A Ctrl+C press, or an event that disarms an armed quit: a key press
  # other than Ctrl+C, or a paste. A release or a repeat is not a new key.
  defguard handles?(quit, event)
           when (is_struct(event, Key) and event.kind == "press" and
                   (quit != nil or {event.code, event.modifiers} == {"c", ["ctrl"]})) or
                  (quit != nil and is_struct(event, Paste))

  @doc """
  The answer to an event that `handles?/2` accepts. `:quit` for a Ctrl+C
  while armed; `{:clear, quit}` for a first Ctrl+C, which arms a new window,
  with the hint when `nothing_to_clear?`; `{:pass, nil}` for an event that
  disarms, which then runs as usual.
  """
  @spec handle(t(), struct(), nothing_to_clear? :: boolean()) ::
          :quit | {:clear, t()} | {:pass, nil}
  def handle(quit, %{__struct__: Key, code: "c", modifiers: ["ctrl"]}, nothing_to_clear?) do
    case quit do
      {_ref, _hint?} ->
        :quit

      nil ->
        ref = make_ref()
        Process.send_after(self(), {__MODULE__, ref}, @window_ms)
        {:clear, {ref, nothing_to_clear?}}
    end
  end

  def handle({_ref, _hint?}, _event, _nothing_to_clear?), do: {:pass, nil}

  @doc "The end of a window disarms only the arm that made it."
  @spec expire(t(), reference()) :: t()
  def expire({ref, _hint?}, ref), do: nil
  def expire(quit, _ref), do: quit

  @doc """
  The footer hint while an arm on a composer that was empty and is still
  empty lasts, else nil. A text that an event gives back during the window
  hides the hint, as the second Ctrl+C would clear it.
  """
  @spec hint(t(), nothing_to_clear? :: boolean()) :: String.t() | nil
  def hint({_ref, true}, true), do: "Ctrl+C again to quit"
  def hint(_quit, _nothing_to_clear?), do: nil
end
