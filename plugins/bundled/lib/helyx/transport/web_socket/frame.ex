defmodule Helyx.Transport.WebSocket.Frame do
  @moduledoc false
  # The JSON codec of the wire frames and their parts
  # (`docs/features/wire-protocol.md`, "Parts").

  @max_frame 1_048_576
  @max_piece 786_000
  @max_digits 1_024
  # The bytes of a frame joined from parts and its values, by the direction
  # of the frame: an inbound frame of a client, and an outbound frame of the
  # server, which a client reads (`docs/features/wire-protocol.md`, "Bounds";
  # the derivation in `docs/features/tui-attach.md`, decision 13).
  @bounds %{inbound: {26_214_400, 65_536}, outbound: {1_611_661_312, 38_797_312}}

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

  # One text of `direction` with the parts joined so far: nil, or the next
  # `n` and the joined bytes, one binary, so an empty part keeps nothing.
  # Gives `{:frame, map}`, `{:joined, map}` from parts, `{:more, parts}`, or
  # `{:close, code}`. `json/2` refuses a text that is not UTF-8, or that is
  # over the decode bounds.
  def decode(text, parts, direction \\ :inbound) do
    {_max_joined, max_values} = bounds = Map.fetch!(@bounds, direction)

    case {json(text, max_values), parts} do
      {{:ok, %{"type" => "part"} = part}, _parts} -> join(part, parts || {0, ""}, bounds)
      {{:ok, %{"type" => type} = frame}, nil} when is_binary(type) -> {:frame, frame}
      _ -> {:close, 4400}
    end
  end

  defp join(%{"n" => n, "last" => last, "data" => data} = part, {n, joined}, bounds)
       when map_size(part) == 4 and is_boolean(last) and is_binary(data) do
    {max_joined, _max_values} = bounds

    with {:ok, piece} <- Base.decode64(data),
         true <- byte_size(joined) + byte_size(piece) <= max_joined || {:close, 4413} do
      joined(last, {n + 1, <<joined::binary, piece::binary>>}, bounds)
    else
      :error -> {:close, 4400}
      close -> close
    end
  end

  defp join(_part, _parts, _bounds), do: {:close, 4400}

  defp joined(false, parts, _bounds), do: {:more, parts}

  defp joined(true, {_n, joined}, {_max_joined, max_values}) do
    case json(joined, max_values) do
      {:ok, %{"type" => type} = frame} when is_binary(type) and type != "part" ->
        {:joined, frame}

      _ ->
        {:close, 4400}
    end
  end

  # `JSON.decode/1` with each string a copy: a decoded string of more than
  # 64 bytes is otherwise a part of the frame text, up to the joined bound, and keeps
  # it alive in each process that the string reaches. The decode stops at
  # the first value over `max_values` or the first integer over
  # `@max_digits`: the decode bounds of the memory and the work of one
  # decode (`docs/features/wire-protocol.md`, "Bounds").
  defp json(text, max_values) do
    decoders = [
      string: &:binary.copy/1,
      integer: &integer/1,
      array_start: &array_start/1,
      array_push: &array_push/2,
      array_finish: &array/2,
      object_start: &object_start/1,
      object_push: &object_push/3,
      object_finish: &object/2
    ]

    case JSON.decode(text, {max_values, []}, decoders) do
      {value, _acc, ""} -> {:ok, value}
      _error_or_rest -> :error
    end
  catch
    :over -> :error
  end

  defp integer(digits) when byte_size(digits) <= @max_digits, do: String.to_integer(digits)
  defp integer(_digits), do: throw(:over)

  # The accumulator is `{left, items}` in an array and `{left, pairs,
  # :object}` in an object: the values and keys that the whole text may
  # still decode, and the items of the open array or object. An array or an
  # object counts at its start, with its key, so a nesting counts before its
  # end.
  defp array_start(parent), do: {opened(parent), []}
  defp object_start(parent), do: {opened(parent), [], :object}

  defp opened({left, _items}), do: take(left, 1)
  defp opened({left, _pairs, :object}), do: take(left, 2)

  defp array_push(value, {left, items}) when is_list(value) or is_map(value),
    do: {left, [value | items]}

  defp array_push(value, {left, items}), do: {take(left, 1), [value | items]}

  defp object_push(key, value, {left, pairs, :object}) when is_list(value) or is_map(value),
    do: {left, [{key, value} | pairs], :object}

  defp object_push(key, value, {left, pairs, :object}),
    do: {take(left, 2), [{key, value} | pairs], :object}

  defp array({left, items}, parent), do: {:lists.reverse(items), put_elem(parent, 0, left)}

  # The first of two equal keys wins, as in `JSON.decode/1`.
  defp object({left, pairs, :object}, parent),
    do: {:maps.from_list(pairs), put_elem(parent, 0, left)}

  defp take(left, more) when more <= left, do: left - more
  defp take(_left, _more), do: throw(:over)
end
