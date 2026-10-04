defmodule Helyx.TUI.Quit do
  @moduledoc false
  # The double Ctrl+C of the TUI (#486). A first Ctrl+C clears the composer
  # and arms the quit for @window_ms; a second one while armed quits. Any
  # other key press or a paste disarms it, and so does the end of the
  # window: the message `{Helyx.TUI.Quit, ref}` that a first Ctrl+C sends to
  # the calling process. The ExRatatui events are named only as atoms, in
  # guards and map patterns, so this module needs no guard of the optional
  # dependency (ADR 0005).

  alias ExRatatui.Event.{Key, Paste}

  @window_ms 500

  # nil while disarmed, or the ref of the armed window and whether the
  # footer shows the hint.
  @type t :: nil | {reference(), hint? :: boolean()}

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

  @doc "The footer hint while an arm on an empty composer lasts, else nil."
  @spec hint(t()) :: String.t() | nil
  def hint({_ref, true}), do: "Ctrl+C again to quit"
  def hint(_quit), do: nil
end
