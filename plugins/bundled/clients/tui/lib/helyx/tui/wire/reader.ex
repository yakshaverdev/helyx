defmodule Helyx.TUI.Wire.Reader do
  @moduledoc false
  # The WebSocket messages of the server in the bytes that
  # `Helyx.TUI.Wire.Connection` read so far, with the frame rules of the
  # handshake (`Helyx.TUI.Wire.check/4`): the fragments of a text joined,
  # at most the frame bound of the wire. The header of a frame is checked
  # before its payload is whole, so the buffer holds at most one frame of
  # the bound and the bytes of one read after it.

  alias Helyx.TUI.Wire

  @type message :: {:text, binary()} | {:ping, binary()} | {:close, binary()}

  # `{:ok, messages, rest, joined}`: the whole messages, oldest first; the
  # bytes of the next frame, which is not whole yet; and the fragments of
  # a text so far, or nil. A frame that the contract does not allow gives
  # `:broken`.
  @spec read(binary(), binary() | nil) :: {:ok, [message()], binary(), binary() | nil} | :broken
  def read(buffer, joined), do: read(buffer, joined, [])

  defp read(buffer, joined, acc) do
    with {:ok, fin, opcode, size, at} <- header(buffer),
         :ok <- Wire.check(opcode, fin, size, joined),
         <<_header::binary-size(at), payload::binary-size(size), rest::binary>> <- buffer do
      {acc, joined} = message(opcode, fin, payload, joined, acc)
      read(rest, joined, acc)
    else
      {:error, :broken} -> :broken
      _more -> {:ok, Enum.reverse(acc), buffer, joined}
    end
  end

  # A server does not mask (RFC 6455, section 5.1) and sets no reserved bit.
  defp header(<<fin::1, 0::3, opcode::4, 0::1, len::7, rest::binary>>) do
    case {len, rest} do
      {126, <<size::16, _::binary>>} -> {:ok, fin, opcode, size, 4}
      {127, <<size::64, _::binary>>} -> {:ok, fin, opcode, size, 10}
      {len, _rest} when len > 125 -> :more
      {len, _rest} -> {:ok, fin, opcode, len, 2}
    end
  end

  defp header(<<_::16, _::binary>>), do: {:error, :broken}
  defp header(_short), do: :more

  defp message(8, _fin, payload, joined, acc), do: {[{:close, payload} | acc], joined}
  defp message(9, _fin, payload, joined, acc), do: {[{:ping, payload} | acc], joined}
  defp message(10, _fin, _payload, joined, acc), do: {acc, joined}

  defp message(_text, 1, payload, joined, acc),
    do: {[{:text, (joined || "") <> payload} | acc], nil}

  defp message(_text, 0, payload, joined, acc), do: {acc, (joined || "") <> payload}
end
