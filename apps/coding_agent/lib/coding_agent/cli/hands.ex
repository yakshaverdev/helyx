defmodule CodingAgent.CLI.Hands do
  @moduledoc false
  # `helyx hands --pair <link>` and `helyx hands --name <name>`
  # (`docs/features/remote-hands.md`, "The runner state"). The command
  # pairs or loads the saved key, runs the runner in the foreground, prints
  # one line for each reconnection state change, and ends with 0 at a stop
  # or 1 for a fault that a retry cannot pass.

  alias Helyx.Transport.WebSocket
  alias Helyx.Transport.WebSocket.Pairing
  alias Helyx.Transport.WebSocket.Runner
  alias Helyx.Transport.WebSocket.Runner.{Link, State}

  # The runner's supervisor, which a stop of the command stops.
  @supervisor CodingAgent.Hands

  def run(opts, [], home) do
    with :ok <- switches(opts),
         :ok <- one(opts),
         {:ok, prepared} <- prepare(opts, home),
         {:ok, _apps} <- Application.ensure_all_started(:coding_agent),
         {:ok, supervisor} <- start(prepared) do
      case monitor(supervisor, prepared) do
        :ok -> :ok
        {:error, reason} -> {:error, error_text(reason, opts)}
      end
    else
      {:error, reason} -> {:error, error_text(reason, opts)}
    end
  end

  def run(_opts, args, _home) do
    if Enum.any?(args, &link_argument?/1) do
      {:error, "a pair link goes after --pair, not as an argument"}
    else
      {:error, "hands takes no directory argument, got #{length(args)} argument(s)"}
    end
  end

  defp link_argument?(argument) when is_binary(argument),
    do: String.starts_with?(argument, Link.scheme())

  defp link_argument?(_argument), do: false

  defp switches(opts) do
    case Enum.find(Keyword.keys(opts), &(&1 not in [:pair, :name, :folder])) do
      nil -> :ok
      name -> {:error, "--#{name} does not combine with hands"}
    end
  end

  defp one(opts) do
    case {Keyword.fetch(opts, :pair), Keyword.fetch(opts, :name)} do
      {:error, :error} -> {:error, "hands needs --pair <link> or --name <name>"}
      {{:ok, _link}, {:ok, _name}} -> {:error, "--pair does not combine with --name"}
      {{:ok, link}, :error} when is_binary(link) -> :ok
      {:error, {:ok, name}} when is_binary(name) -> name(name)
      _other -> {:error, "hands takes one of --pair <link> and --name <name>"}
    end
  end

  defp name(name) do
    if Pairing.name?(name),
      do: :ok,
      else: {:error, "--name takes 1 to 64 bytes of a-z, 0-9, and _"}
  end

  defp prepare(opts, home) do
    case Runner.prepare(runner_opts(opts, home)) do
      {:ok, prepared} -> {:ok, prepared}
      {:error, reason} -> {:error, error_text(reason, opts)}
    end
  end

  defp runner_opts(opts, home) do
    mode = if opts[:pair], do: [link: opts[:pair]], else: [name: opts[:name]]

    folder =
      cond do
        opts[:folder] -> [folder: opts[:folder]]
        opts[:pair] -> [folder: File.cwd!()]
        true -> []
      end

    [home: home, notify: self()] ++ mode ++ folder
  end

  defp start(prepared) do
    case Supervisor.start_link([{Runner, prepared}], strategy: :one_for_one, name: @supervisor) do
      {:ok, supervisor} -> {:ok, supervisor}
      {:error, {:already_started, _pid}} -> {:error, "a runner runs in this VM already"}
      {:error, reason} -> {:error, "could not start the runner: #{Helyx.Reason.text(reason)}"}
    end
  end

  defp monitor(supervisor, prepared) do
    case Supervisor.which_children(supervisor) do
      [{_id, pid, _type, _modules}] ->
        ref = Process.monitor(pid)
        loop(ref, prepared)

      [] ->
        ended()
    end
  end

  defp loop(ref, prepared) do
    receive do
      {:hands, {:ended, reason}} ->
        result({:shutdown, reason})

      {:hands, {:connected, %{first?: true} = info}} ->
        IO.puts(connected(prepared, info))
        loop(ref, prepared)

      {:hands, {:connected, %{first?: false}}} ->
        IO.puts("helyx: connected again")
        loop(ref, prepared)

      {:hands, :waiting} ->
        IO.puts("helyx: the server does not answer; the runner keeps trying")
        loop(ref, prepared)

      {:DOWN, ^ref, :process, _pid, reason} ->
        result(reason)
    end
  end

  # The runner ended before the monitor was set: its result is already a
  # message, so every fault keeps its one line.
  defp ended do
    receive do
      {:hands, {:ended, reason}} -> result({:shutdown, reason})
      {:hands, _event} -> ended()
    after
      5_000 -> {:error, :runner_stopped}
    end
  end

  defp connected(%{mode: :pair}, %{name: name, address: address}),
    do: "helyx: the runner #{name} is paired with #{address} and connected"

  defp connected(_prepared, %{name: name, address: address}),
    do: "helyx: the runner #{name} is connected to #{address}"

  defp result({:shutdown, :unauthorized}), do: {:error, :unauthorized}
  defp result({:shutdown, reason}), do: {:error, reason}
  defp result(:shutdown), do: :ok
  defp result(:normal), do: :ok
  defp result(reason), do: {:error, reason}

  defp error_text({:link, reason}, _opts), do: link_error(reason)

  defp error_text({:state_file, path, :enoent}, opts),
    do: "no saved runner state for #{inspect(opts[:name])} at #{path}; pair the runner first"

  defp error_text({:state_file, path, :exists}, _opts) do
    name = Path.basename(path, ".json")
    "a runner state for #{name} already exists at #{path}; use helyx hands --name #{name}"
  end

  defp error_text({:state_file, path, :symlink}, _opts),
    do: "the runner state #{path} is a symlink; remove it and pair the runner again"

  defp error_text({:state_file, path, :not_regular}, _opts),
    do: "the runner state #{path} is not a regular file"

  defp error_text({:state_file, path, :loose_mode}, _opts),
    do: "the runner state #{path} is readable by other users; run chmod 600 on it"

  defp error_text({:state_file, path, :too_large}, _opts),
    do: "the runner state #{path} is over #{State.max_bytes()} bytes"

  defp error_text({:state_file, path, :bad_json}, _opts),
    do: "the runner state #{path} is not valid JSON"

  defp error_text({:state_file, path, :bad_field}, _opts),
    do: "the runner state #{path} has a field of the wrong type"

  defp error_text({:state_file, path, :bad_key}, _opts),
    do: "the runner state #{path} has no valid Ed25519 key"

  defp error_text({:state_file, path, :name_mismatch}, _opts),
    do: "the runner state #{path} is for another runner"

  defp error_text({:state_file, path, :bad_address}, _opts),
    do: "the runner state #{path} has an address that is not host:port"

  defp error_text({:state_file, path, reason}, _opts),
    do: "the runner state #{path}: #{Helyx.Reason.text(reason)}"

  defp error_text({:folder, :missing}, _opts), do: "hands needs --folder <dir> when it pairs"

  defp error_text({:folder, :too_long, _folder}, _opts),
    do: "the folder is over #{Pairing.max_folder_bytes()} bytes"

  defp error_text({:folder, :not_a_directory, folder}, _opts) do
    if String.starts_with?(folder, Link.scheme()),
      do: "the folder is not a directory",
      else: "not a directory: #{inspect(folder)}"
  end

  defp error_text({:folder, :not_a_directory}, _opts), do: "the folder is not a directory"

  defp error_text({:folder, :invalid_utf8, _folder}, _opts),
    do: "the folder is not valid UTF-8"

  defp error_text({:name, :bad_name}, _opts),
    do: "--name takes 1 to 64 bytes of a-z, 0-9, and _"

  defp error_text(:unauthorized, _opts),
    do: "the server refused the runner key; pair the runner again"

  defp error_text(:bad_pin, _opts),
    do: "the certificate of the server does not match the pin of the link"

  defp error_text(:runner_stopped, _opts), do: "the runner stopped before it started"

  defp error_text({:refused, server}, _opts),
    do:
      "the server speaks protocol #{server}, this runner speaks " <>
        "#{WebSocket.protocol()}; install the same build"

  defp error_text(reason, _opts), do: Helyx.Reason.text(reason)

  defp link_error(:link_too_long),
    do: "the pair link is over #{Runner.Link.max_bytes()} bytes"

  defp link_error(:bad_prefix),
    do: "the pair link does not start with helyx-pair:1:"

  defp link_error(:bad_encoding),
    do: "the pair link does not hold a base64url JSON object"

  defp link_error(:bad_field),
    do: "the pair link misses a field, or a field is not a string"

  defp link_error(:bad_kind), do: "the pair link is not for a runner"

  defp link_error(:bad_name),
    do: "the pair link has a name of 1 to 64 bytes of a-z, 0-9, and _"

  defp link_error(:bad_port), do: "the pair link has a port outside 1 to 65535"

  defp link_error(:bad_address), do: "the pair link has no valid host:port address"
end
