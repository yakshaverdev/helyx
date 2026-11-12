defmodule Helyx.Tool.Args do
  @moduledoc false
  # The check of a tool's arguments at its entry, from the JSON schema that
  # the tool declares in `parameters/0`. `check/2` answers `{:ok, args}`
  # with the defaults filled in, or `{:error, text}` for the first argument
  # that does not fit.
  #
  # A property whose value is `null` is the same as an absent one, so its
  # default applies; a required property that is `null` is an error.
  # `minLength` and `maxLength` count bytes, as the tool
  # descriptions state, not the code points of JSON Schema. Another keyword
  # raises, so a new tool cannot use a keyword that nothing checks.
  # `additionalProperties: false` refuses a key that `properties` does not
  # name, with `"<key> is not an argument"`.

  @keywords ~w(type properties required additionalProperties enum minimum maximum
               minLength maxLength items minItems maxItems default description)
  @types ~w(object array string integer number boolean)

  # Each keyword that states a rule, and the types that it fits.
  @constrained %{
    "properties" => ~w(object),
    "required" => ~w(object),
    "additionalProperties" => ~w(object),
    "minimum" => ~w(integer number),
    "maximum" => ~w(integer number),
    "minLength" => ~w(string),
    "maxLength" => ~w(string),
    "minItems" => ~w(array),
    "maxItems" => ~w(array),
    "items" => ~w(array),
    "additionalProperties" => ~w(object)
  }

  @doc false
  @spec check(map(), map()) :: {:ok, map()} | {:error, String.t()}
  def check(%{} = args, %{} = schema) do
    validate(schema, nil)
    value(schema, args, nil)
  end

  # The whole schema is read before any value is: a keyword that this module
  # does not know, a type that it does not know, and a rule on a type that
  # it does not fit raise at the first call, even on a property that this
  # call leaves out. An unchecked keyword would pass in silence.
  defp validate(schema, path) do
    keywords(schema, path)

    case schema do
      %{"type" => "object", "properties" => properties} ->
        Enum.each(properties, fn {name, sub} -> validate(sub, join(path, name)) end)

      %{"type" => "array", "items" => items} when is_map(items) ->
        validate(items, "#{path || "the root"}[]")

      _other ->
        :ok
    end
  end

  defp keywords(schema, path) do
    Enum.each(schema, fn {key, value} ->
      cond do
        key not in @keywords ->
          raise ArgumentError, "unknown schema keyword #{inspect(key)} at #{where(path)}"

        key == "type" and value not in @types ->
          raise ArgumentError, "unknown schema type #{inspect(value)} at #{where(path)}"

        key == "additionalProperties" and not is_boolean(value) ->
          raise ArgumentError,
                "the schema keyword \"additionalProperties\" takes true or false at #{where(path)}"

        Map.has_key?(@constrained, key) and schema["type"] not in @constrained[key] ->
          raise ArgumentError,
                "the schema keyword #{inspect(key)} does not fit the type " <>
                  "#{inspect(schema["type"])} at #{where(path)}"

        true ->
          :ok
      end
    end)
  end

  defp value(schema, value, path) do
    with :ok <- type(schema, value, path),
         :ok <- rules(schema, value, path) do
      nested(schema, value, path)
    end
  end

  defp type(%{"type" => "string"}, value, _path) when is_binary(value), do: :ok
  defp type(%{"type" => "integer"}, value, _path) when is_integer(value), do: :ok
  defp type(%{"type" => "number"}, value, _path) when is_number(value), do: :ok
  defp type(%{"type" => "boolean"}, value, _path) when is_boolean(value), do: :ok
  defp type(%{"type" => "array"}, value, _path) when is_list(value), do: :ok
  defp type(%{"type" => "object"}, value, _path) when is_map(value), do: :ok
  defp type(%{"type" => type}, _value, path), do: {:error, "#{path} must be #{article(type)}"}
  defp type(_schema, _value, _path), do: :ok

  defp article("object"), do: "an object"
  defp article("array"), do: "a list"
  defp article("integer"), do: "an integer"
  defp article("number"), do: "a number"
  defp article("boolean"), do: "true or false"
  defp article("string"), do: "a string"

  defp rules(schema, value, path) do
    with :ok <- one_of(schema, value, path), do: bounds(schema, value, path)
  end

  defp one_of(%{"enum" => allowed}, value, path) do
    if value in allowed,
      do: :ok,
      else: {:error, "#{path} must be one of #{Enum.join(allowed, ", ")}"}
  end

  defp one_of(_schema, _value, _path), do: :ok

  defp bounds(%{"type" => "string"} = schema, value, path),
    do: size(schema, path, byte_size(value), "a string", {"byte", "bytes"})

  defp bounds(%{"type" => "array"} = schema, value, path),
    do: size(schema, path, length(value), "a list", {"item", "items"})

  defp bounds(%{"type" => type} = schema, value, path) when type in ~w(integer number),
    do: range(schema, value, path, article(type))

  defp bounds(_schema, _value, _path), do: :ok

  defp range(schema, value, path, article) do
    min = schema["minimum"]
    max = schema["maximum"]

    case side(min, max, value) do
      :ok -> :ok
      :both -> {:error, "#{path} must be #{article} from #{min} to #{max}"}
      :min -> {:error, "#{path} must be #{article} of #{min} or more"}
      :max -> {:error, "#{path} must be #{article} of #{max} or less"}
    end
  end

  # Which bound `n` breaks: `:both` names the two bounds of a schema that has both.
  defp side(nil, nil, _n), do: :ok
  defp side(min, nil, n), do: if(n < min, do: :min, else: :ok)
  defp side(nil, max, n), do: if(n > max, do: :max, else: :ok)
  defp side(min, max, n), do: if(n < min or n > max, do: :both, else: :ok)

  defp size(schema, path, length, noun, unit) do
    min = schema["minLength"] || schema["minItems"]
    max = schema["maxLength"] || schema["maxItems"]

    case side(min, max, length) do
      :ok -> :ok
      :both -> {:error, "#{path} must be #{noun} of #{min} to #{max} #{plural(max, unit)}"}
      :min -> {:error, "#{path} must be #{noun} of at least #{min} #{plural(min, unit)}"}
      :max -> {:error, "#{path} must be #{noun} of at most #{max} #{plural(max, unit)}"}
    end
  end

  defp plural(1, {one, _many}), do: one
  defp plural(_count, {_one, many}), do: many

  defp nested(%{"type" => "object"} = schema, value, path), do: object(schema, value, path)
  defp nested(%{"type" => "array"} = schema, value, path), do: array(schema, value, path)
  defp nested(_schema, value, _path), do: {:ok, value}

  defp object(schema, value, path) do
    properties = Map.get(schema, "properties", %{})
    required = Map.get(schema, "required", [])

    case extra(schema, value, properties, path) do
      :ok -> fields(properties, value, required, path)
      {:error, text} -> {:error, text}
    end
  end

  defp fields(properties, value, required, path) do
    Enum.reduce_while(properties, {:ok, value}, fn {name, sub}, {:ok, acc} ->
      case property(sub, Map.get(value, name), name in required, path, name) do
        :absent -> {:cont, {:ok, Map.delete(acc, name)}}
        {:ok, checked} -> {:cont, {:ok, Map.put(acc, name, checked)}}
        {:error, text} -> {:halt, {:error, text}}
      end
    end)
  end

  # A key that the schema does not name is an error only when the schema
  # says so, so a tool that keeps its unknown keys does not change.
  defp extra(%{"additionalProperties" => false}, value, properties, path) do
    case Enum.find(Enum.sort(Map.keys(value)), &(not Map.has_key?(properties, &1))) do
      nil -> :ok
      name -> {:error, "#{join(path, name)} is not an argument"}
    end
  end

  defp extra(_schema, _value, _properties, _path), do: :ok

  defp property(_sub, nil, true, path, name), do: {:error, "#{join(path, name)} is required"}
  defp property(%{"default" => default}, nil, false, _path, _name), do: {:ok, default}
  defp property(_sub, nil, false, _path, _name), do: :absent
  defp property(sub, value, _required, path, name), do: value(sub, value, join(path, name))

  defp array(schema, value, path) do
    case schema["items"] do
      nil -> {:ok, value}
      sub -> each(sub, value, path, 0, [])
    end
  end

  defp each(_sub, [], _path, _index, acc), do: {:ok, Enum.reverse(acc)}

  defp each(sub, [item | rest], path, index, acc) do
    case value(sub, item, "#{path}[#{index}]") do
      {:ok, checked} -> each(sub, rest, path, index + 1, [checked | acc])
      {:error, text} -> {:error, text}
    end
  end

  defp join(nil, name), do: name
  defp join(path, name), do: path <> "." <> name

  defp where(nil), do: "the root"
  defp where(path), do: path
end
