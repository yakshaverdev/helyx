defmodule Helyx.Session.Hands.Term.Answer.Hands do
  @moduledoc false
  # The answers that the hands send to the session: the capability report, the
  # start of a provider process, the cancel and the revoke, the stop, and the
  # read of the folder. The answers that the session sends are in
  # `Helyx.Session.Hands.Term.Answer`.

  alias Helyx.Hook
  alias Helyx.Session.Hands.Term.Data

  @kinds [
    open_answer: "hands.open_answer",
    provider_start_answer: "hands.provider_start_answer",
    cancel_answer: "hands.cancel_answer",
    revoke_answer: "hands.revoke_answer",
    stop_answer: "hands.stop_answer",
    read_answer: "hands.read_answer"
  ]

  @doc false
  def kinds, do: @kinds

  @doc false
  def direction(_tag), do: :hands_to_session

  def check(
        %{
          t: :open_answer,
          instance: instance,
          specs: specs,
          concurrent: concurrent,
          providers: providers,
          hooks: hooks,
          folder: folder
        } = term
      ) do
    if map_size(term) == 7 and Data.id?(instance) and Data.list?(specs, &Data.spec?/1) and
         Data.list?(concurrent, &Data.text?/1) and Data.list?(providers, &Data.plugin?/1) and
         hooks?(hooks) and Data.cwd?(folder),
       do: {:ok, term},
       else: :error
  end

  def check(%{t: :open_answer, instance: instance, error: error} = term) do
    if map_size(term) == 3 and Data.id?(instance) and Data.reason?(error),
      do: {:ok, term},
      else: :error
  end

  def check(%{t: :provider_start_answer, instance: instance, id: id, ok: true} = term) do
    if map_size(term) == 4 and Data.id?(instance) and Data.id?(id), do: {:ok, term}, else: :error
  end

  def check(%{t: :provider_start_answer, instance: instance, id: id, error: error} = term) do
    if map_size(term) == 4 and Data.id?(instance) and Data.id?(id) and Data.reason?(error),
      do: {:ok, term},
      else: :error
  end

  def check(%{t: :cancel_answer, instance: instance, result: :ok} = term) do
    if map_size(term) == 3 and Data.id?(instance), do: {:ok, term}, else: :error
  end

  def check(%{t: :cancel_answer, instance: instance, error: error} = term) do
    if map_size(term) == 3 and Data.id?(instance) and Data.reason?(error),
      do: {:ok, term},
      else: :error
  end

  def check(%{t: :revoke_answer, instance: instance, ids: ids, error: error} = term) do
    if map_size(term) == 4 and Data.id?(instance) and Data.list?(ids, &Data.id?/1) and
         (is_nil(error) or Data.reason?(error)),
       do: {:ok, term},
       else: :error
  end

  def check(%{t: :stop_answer, instance: instance, unconfirmed: unconfirmed} = term) do
    if map_size(term) == 3 and Data.id?(instance) and Data.list?(unconfirmed, &Data.reason?/1),
      do: {:ok, term},
      else: :error
  end

  def check(%{t: :read_answer, instance: instance, files: files} = term) do
    if map_size(term) == 3 and Data.id?(instance) and Data.list?(files, &file?/1),
      do: {:ok, term},
      else: :error
  end

  def check(%{t: :read_answer, instance: instance, error: error} = term) do
    if map_size(term) == 3 and Data.id?(instance) and Data.reason?(error),
      do: {:ok, term},
      else: :error
  end

  def check(_term), do: :error

  @file_errors [:enoent, :too_large, :not_regular, :eacces]

  defp hooks?(hooks) do
    is_map(hooks) and not is_struct(hooks) and
      Enum.all?(hooks, fn {point, entries} ->
        point in Hook.points() and
          Data.list?(entries, fn
            {hook, ms} -> Data.plugin?(hook) and is_integer(ms) and ms in 1..Hook.max_limit_ms()
            _entry -> false
          end)
      end)
  end

  defp hooks_to_map(hooks) do
    hooks
    |> Enum.sort_by(fn {point, _entries} -> point end)
    |> Map.new(fn {point, entries} ->
      {Atom.to_string(point), Enum.map(entries, fn {hook, ms} -> [hook, ms] end)}
    end)
  end

  defp to_hooks(%{} = map) when not is_struct(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {point, entries}, {:ok, acc} ->
      with {:ok, point} <- point(point),
           {:ok, entries} <- to_hook_entries(entries) do
        {:cont, {:ok, Map.put(acc, point, entries)}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp to_hooks(_hooks), do: :error

  defp to_hook_entries(entries) when is_list(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn
      [hook, ms], {:ok, acc} -> {:cont, {:ok, [{hook, ms} | acc]}}
      _entry, _acc -> {:halt, :error}
    end)
    |> Data.reversed()
  end

  defp to_hook_entries(_entries), do: :error

  defp point("before_tool"), do: {:ok, :before_tool}
  defp point("after_tool"), do: {:ok, :after_tool}
  defp point("before_settle"), do: {:ok, :before_settle}
  defp point(_point), do: :error

  defp file?(%{path: path, text: text} = file),
    do: map_size(file) == 2 and Data.path?(path) and Data.text?(text)

  defp file?(%{path: path, error: error} = file),
    do: map_size(file) == 2 and Data.path?(path) and error in @file_errors

  defp file?(_file), do: false

  # --- the JSON map of each answer ---

  @doc false
  def encode(%{t: :open_answer, error: error} = term) do
    {:ok, %{"t" => "hands.open_answer", "instance" => term.instance, "error" => error}}
  end

  def encode(%{t: :open_answer} = term) do
    {:ok,
     %{
       "t" => "hands.open_answer",
       "instance" => term.instance,
       "specs" => Enum.map(term.specs, &Data.spec_to_map/1),
       "concurrent" => term.concurrent,
       "providers" => term.providers,
       "hooks" => hooks_to_map(term.hooks),
       "folder" => term.folder
     }}
  end

  def encode(%{t: :provider_start_answer, error: error} = term) do
    {:ok,
     %{
       "t" => "hands.provider_start_answer",
       "instance" => term.instance,
       "id" => term.id,
       "error" => error
     }}
  end

  def encode(%{t: :provider_start_answer} = term) do
    {:ok,
     %{
       "t" => "hands.provider_start_answer",
       "instance" => term.instance,
       "id" => term.id,
       "ok" => true
     }}
  end

  def encode(%{t: :cancel_answer, error: error} = term) do
    {:ok, %{"t" => "hands.cancel_answer", "instance" => term.instance, "error" => error}}
  end

  def encode(%{t: :cancel_answer} = term) do
    {:ok, %{"t" => "hands.cancel_answer", "instance" => term.instance, "result" => "ok"}}
  end

  def encode(%{t: :revoke_answer} = term) do
    {:ok,
     %{
       "t" => "hands.revoke_answer",
       "instance" => term.instance,
       "ids" => term.ids,
       "error" => term.error
     }}
  end

  def encode(%{t: :stop_answer} = term) do
    {:ok,
     %{
       "t" => "hands.stop_answer",
       "instance" => term.instance,
       "unconfirmed" => term.unconfirmed
     }}
  end

  def encode(%{t: :read_answer, error: error} = term) do
    {:ok, %{"t" => "hands.read_answer", "instance" => term.instance, "error" => error}}
  end

  def encode(%{t: :read_answer} = term) do
    {:ok,
     %{
       "t" => "hands.read_answer",
       "instance" => term.instance,
       "files" => Enum.map(term.files, &file_to_map/1)
     }}
  end

  defp file_to_map(%{text: text} = file), do: %{"path" => file.path, "text" => text}

  defp file_to_map(%{error: error} = file),
    do: %{"path" => file.path, "error" => Atom.to_string(error)}

  # --- the answer of a JSON map ---

  @doc false
  def decode(%{"t" => "hands.open_answer", "specs" => specs} = map) when is_list(specs) do
    Data.decode_fields(map, ~w(instance specs concurrent providers hooks folder), fn
      [instance, specs, concurrent, providers, hooks, folder] ->
        with {:ok, specs} <- to_specs(specs),
             {:ok, hooks} <- to_hooks(hooks) do
          check(%{
            t: :open_answer,
            instance: instance,
            specs: specs,
            concurrent: concurrent,
            providers: providers,
            hooks: hooks,
            folder: folder
          })
        end
    end)
  end

  def decode(%{"t" => "hands.open_answer"} = map) do
    Data.decode_fields(map, ~w(instance error), fn [instance, error] ->
      check(%{t: :open_answer, instance: instance, error: error})
    end)
  end

  def decode(%{"t" => "hands.provider_start_answer", "ok" => true} = map) do
    Data.decode_fields(map, ~w(instance id ok), fn [instance, id, true] ->
      check(%{t: :provider_start_answer, instance: instance, id: id, ok: true})
    end)
  end

  def decode(%{"t" => "hands.provider_start_answer"} = map) do
    Data.decode_fields(map, ~w(instance id error), fn [instance, id, error] ->
      check(%{t: :provider_start_answer, instance: instance, id: id, error: error})
    end)
  end

  def decode(%{"t" => "hands.cancel_answer", "result" => "ok"} = map) do
    Data.decode_fields(map, ~w(instance result), fn [instance, "ok"] ->
      check(%{t: :cancel_answer, instance: instance, result: :ok})
    end)
  end

  def decode(%{"t" => "hands.cancel_answer"} = map) do
    Data.decode_fields(map, ~w(instance error), fn [instance, error] ->
      check(%{t: :cancel_answer, instance: instance, error: error})
    end)
  end

  def decode(%{"t" => "hands.revoke_answer"} = map) do
    Data.decode_fields(map, ~w(instance ids error), fn [instance, ids, error] ->
      check(%{t: :revoke_answer, instance: instance, ids: ids, error: error})
    end)
  end

  def decode(%{"t" => "hands.stop_answer"} = map) do
    Data.decode_fields(map, ~w(instance unconfirmed), fn [instance, unconfirmed] ->
      check(%{t: :stop_answer, instance: instance, unconfirmed: unconfirmed})
    end)
  end

  def decode(%{"t" => "hands.read_answer", "files" => files} = map) when is_list(files) do
    Data.decode_fields(map, ~w(instance files), fn [instance, files] ->
      with {:ok, files} <- to_files(files) do
        check(%{t: :read_answer, instance: instance, files: files})
      end
    end)
  end

  def decode(%{"t" => "hands.read_answer"} = map) do
    Data.decode_fields(map, ~w(instance error), fn [instance, error] ->
      check(%{t: :read_answer, instance: instance, error: error})
    end)
  end

  def decode(_map), do: :error

  defp file_error("enoent"), do: {:ok, :enoent}
  defp file_error("too_large"), do: {:ok, :too_large}
  defp file_error("not_regular"), do: {:ok, :not_regular}
  defp file_error("eacces"), do: {:ok, :eacces}
  defp file_error(_error), do: :error

  defp to_files(files) do
    files
    |> Enum.reduce_while({:ok, []}, fn
      %{"path" => path, "text" => text} = map, {:ok, acc} when map_size(map) == 2 ->
        {:cont, {:ok, [%{path: path, text: text} | acc]}}

      %{"path" => path, "error" => error} = map, {:ok, acc} when map_size(map) == 2 ->
        case file_error(error) do
          {:ok, error} -> {:cont, {:ok, [%{path: path, error: error} | acc]}}
          :error -> {:halt, :error}
        end

      _file, _acc ->
        {:halt, :error}
    end)
    |> Data.reversed()
  end

  defp to_specs(specs) do
    specs
    |> Enum.reduce_while({:ok, []}, fn spec, {:ok, acc} ->
      case Data.to_spec(spec) do
        {:ok, spec} -> {:cont, {:ok, [spec | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> Data.reversed()
  end
end
