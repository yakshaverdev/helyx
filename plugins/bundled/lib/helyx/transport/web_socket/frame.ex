defmodule Helyx.Transport.WebSocket.Frame do
  @moduledoc false
  # The JSON codec of the wire frames and their parts
  # (`docs/features/wire-protocol.md`, "Parts").

  @max_frame 1_048_576
  @max_piece 786_000
  @max_joined 26_214_400

  def max_frame, do: @max_frame

  # A frame as the WebSocket texts that carry it, as iodata: one text, or
  # its parts.
  def encode(frame) do
    json = JSON.encode_to_iodata!(frame)

    if IO.iodata_length(json) <= @max_frame,
      do: [json],
      else: json |> IO.iodata_to_binary() |> parts(0)
  end

  defp parts(json, n) when byte_size(json) <= @max_piece, do: [part(n, true, json)]

  defp parts(json, n) do
    <<piece::binary-size(@max_piece), rest::binary>> = json
    [part(n, false, piece) | parts(rest, n + 1)]
  end

  # Base64 needs no JSON escape, so the part goes as iodata with no encode
  # of its data.
  defp part(n, last, piece),
    do: [~s({"type":"part","n":#{n},"last":#{last},"data":"), Base.encode64(piece), ~s("})]

  # One inbound text with the parts joined so far: nil, or the next `n` and
  # the joined bytes, one binary, so an empty part keeps nothing. Gives
  # `{:frame, map}`, `{:joined, map}` from parts, `{:more, parts}`, or
  # `{:close, code}`. `json/1` refuses a text that is not UTF-8 or holds an
  # integer over the largest integer of the BEAM.
  def decode(text, parts) do
    case {json(text), parts} do
      {{:ok, %{"type" => "part"} = part}, _parts} -> join(part, parts || {0, ""})
      {{:ok, %{"type" => type} = frame}, nil} when is_binary(type) -> {:frame, frame}
      _ -> {:close, 4400}
    end
  end

  defp join(%{"n" => n, "last" => last, "data" => data} = part, {n, joined})
       when map_size(part) == 4 and is_boolean(last) and is_binary(data) do
    with {:ok, piece} <- Base.decode64(data),
         true <- byte_size(joined) + byte_size(piece) <= @max_joined || {:close, 4413} do
      joined(last, {n + 1, <<joined::binary, piece::binary>>})
    else
      :error -> {:close, 4400}
      close -> close
    end
  end

  defp join(_part, _parts), do: {:close, 4400}

  defp joined(false, parts), do: {:more, parts}

  defp joined(true, {_n, joined}) do
    case json(joined) do
      {:ok, %{"type" => type} = frame} when is_binary(type) and type != "part" ->
        {:joined, frame}

      _ ->
        {:close, 4400}
    end
  end

  # `JSON.decode/1` with each string a copy: a decoded string of more than
  # 64 bytes is otherwise a part of the frame text, up to 25 MiB, and keeps
  # it alive in each process that the string reaches.
  defp json(text) do
    case JSON.decode(text, :ok, string: &:binary.copy/1) do
      {value, :ok, ""} -> {:ok, value}
      _error_or_rest -> :error
    end
  rescue
    # The decode raises, not returns, for an integer over the BEAM limit.
    SystemLimitError -> :error
  end
end
