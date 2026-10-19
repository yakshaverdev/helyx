defmodule Helyx.Transport.WebSocket.Frame do
  @moduledoc false
  # The JSON codec of the wire frames and their parts
  # (`docs/features/wire-protocol.md`, "Parts").

  @max_frame 1_048_576
  @max_piece 786_000
  @max_joined 26_214_400
  @max_values 65_536
  @max_digits 1_024

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
  # `{:close, code}`. `json/1` refuses a text that is not UTF-8, or that is
  # over the decode bounds.
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
  # it alive in each process that the string reaches. The decode stops at
  # the first value over `@max_values` or the first integer over
  # `@max_digits`: the decode bounds of the memory and the work of one
  # decode (`docs/features/wire-protocol.md`, "Bounds").
  defp json(text) do
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

    case JSON.decode(text, {0, []}, decoders) do
      {value, _acc, ""} -> {:ok, value}
      _error_or_rest -> :error
    end
  catch
    :over -> :error
  end

  defp integer(digits) when byte_size(digits) <= @max_digits, do: String.to_integer(digits)
  defp integer(_digits), do: throw(:over)

  # The accumulator is `{values, items}` in an array and `{values, pairs,
  # :object}` in an object: the values and keys decoded so far in the whole
  # text, and the items of the open array or object. An array or an object
  # counts at its start, with its key, so a nesting counts before its end.
  defp array_start(parent), do: {opened(parent), []}
  defp object_start(parent), do: {opened(parent), [], :object}

  defp opened({values, _items}), do: add(values, 1)
  defp opened({values, _pairs, :object}), do: add(values, 2)

  defp array_push(value, {values, items}) when is_list(value) or is_map(value),
    do: {values, [value | items]}

  defp array_push(value, {values, items}), do: {add(values, 1), [value | items]}

  defp object_push(key, value, {values, pairs, :object}) when is_list(value) or is_map(value),
    do: {values, [{key, value} | pairs], :object}

  defp object_push(key, value, {values, pairs, :object}),
    do: {add(values, 2), [{key, value} | pairs], :object}

  defp array({values, items}, parent), do: {:lists.reverse(items), put_elem(parent, 0, values)}

  # The first of two equal keys wins, as in `JSON.decode/1`.
  defp object({values, pairs, :object}, parent),
    do: {:maps.from_list(pairs), put_elem(parent, 0, values)}

  defp add(values, more) when values + more <= @max_values, do: values + more
  defp add(_values, _more), do: throw(:over)
end
