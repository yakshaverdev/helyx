defmodule Helyx.Transport.WebSocket.Runner.State do
  @moduledoc false
  # The saved state of a paired runner, `<home>/hands/<name>.json`
  # (`docs/features/remote-hands.md`, "The runner state"). The folder has
  # mode 0700 and the file mode 0600 before its first byte. A write goes
  # through a temporary file and a link, so a crash leaves no file or
  # the new one. A read checks the type, the mode, the size, the JSON, and
  # the name, and every error carries the path and never the content.
  #
  # The private key is held in a closure; the caller gets a `:sign` function
  # and the public key, never the seed.

  import Bitwise

  alias Helyx.Session.File.Scan

  @dir "hands"

  # The largest state: a folder of `Pairing.max_folder_bytes/0` (4,096), an
  # address of at most 262 bytes, a pin of 43, a name of 64, a key of 44,
  # and the JSON syntax are under 4,700. 8,192 leaves a margin for a future
  # field.
  @max_bytes 8_192

  @doc "The most bytes of a state file."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "The folder of the state files under `home`."
  @spec dir(Path.t()) :: Path.t()
  def dir(home), do: Path.join(home, @dir)

  @doc "The state file of the runner `name` under `home`."
  @spec path(Path.t(), String.t()) :: Path.t()
  def path(home, name), do: Path.join(dir(home), name <> ".json")

  @doc """
  Writes the state of `name` with the address, the pin, and the folder of
  `fields`, and the private key that `private_key` returns. Gives `:ok` or
  `{:error, {:state_file, path, reason}}`.
  """
  @spec write(Path.t(), String.t(), map(), (-> binary())) ::
          :ok | {:error, {:state_file, Path.t(), term()}}
  def write(home, name, fields, private_key) when is_function(private_key, 0) do
    path = path(home, name)
    dir = dir(home)

    with :ok <- mkdir(dir),
         {:ok, data} <- encode(fields, name, private_key),
         :ok <- write_file(dir, name, path, data) do
      :ok
    else
      {:error, reason} -> {:error, {:state_file, path, reason}}
    end
  end

  @doc """
  Reads the state of `name` under `home`: `{:ok, %{address, pin, name,
  folder, sign, public_key}}`, or `{:error, {:state_file, path, reason}}`.
  """
  @spec read(Path.t(), String.t()) ::
          {:ok, map()} | {:error, {:state_file, Path.t(), term()}}
  def read(home, name) do
    path = path(home, name)

    with {:ok, stat} <- lstat(path),
         :ok <- check(stat, path),
         {:ok, data} <- read_up_to(path),
         :ok <- size(data, path),
         {:ok, fields} <- decode(data, path),
         :ok <- same_name(fields, name, path),
         {:ok, key} <- key(fields["key"], path) do
      {:ok,
       %{
         address: fields["address"],
         pin: fields["pin"],
         name: name,
         folder: fields["folder"],
         sign: sign(key),
         public_key: public(key)
       }}
    end
  end

  defp lstat(path) do
    case File.lstat(path) do
      {:ok, stat} -> {:ok, stat}
      {:error, reason} -> {:error, {:state_file, path, reason}}
    end
  end

  # A symlink is refused before the open: another user could point it at a
  # file that this user reads. The mode is refused, not repaired, because
  # the key may already have been read.
  defp check(%File.Stat{type: :symlink}, path), do: {:error, {:state_file, path, :symlink}}

  defp check(%File.Stat{type: :regular, mode: mode}, path) do
    if (mode &&& 0o077) == 0, do: :ok, else: {:error, {:state_file, path, :loose_mode}}
  end

  defp check(%File.Stat{}, path), do: {:error, {:state_file, path, :not_regular}}

  defp read_up_to(path) do
    case Scan.read_up_to(path, @max_bytes + 1) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, {:state_file, path, reason}}
    end
  end

  defp size(data, path) do
    if byte_size(data) <= @max_bytes, do: :ok, else: {:error, {:state_file, path, :too_large}}
  end

  defp decode(data, path) do
    case Helyx.JSON.decode(data) do
      {:ok, %{} = map} ->
        if Enum.all?(~w(address pin name folder key), &is_binary(map[&1])),
          do: {:ok, map},
          else: {:error, {:state_file, path, :bad_field}}

      _other ->
        {:error, {:state_file, path, :bad_json}}
    end
  end

  defp same_name(%{"name" => name}, name, _path), do: :ok

  defp same_name(_fields, _name, path),
    do: {:error, {:state_file, path, :name_mismatch}}

  defp key(encoded, path) do
    case Base.decode64(encoded) do
      {:ok, <<_key::binary-size(32)>> = key} -> {:ok, key}
      _other -> {:error, {:state_file, path, :bad_key}}
    end
  end

  defp sign(key), do: fn text -> :crypto.sign(:eddsa, :none, text, [key, :ed25519]) end

  defp public(key), do: elem(:crypto.generate_key(:eddsa, :ed25519, key), 0)

  defp mkdir(dir) do
    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700) do
      :ok
    else
      {:error, reason} -> {:error, {:folder, reason}}
    end
  end

  defp encode(fields, name, private_key) do
    key = private_key.()

    {:ok,
     JSON.encode!(%{
       "address" => fields.address,
       "pin" => fields.pin,
       "name" => name,
       "folder" => fields.folder,
       "key" => Base.encode64(key)
     })}
  end

  # The file is 0600 before its first byte: the chmod runs on the open file,
  # which holds no key yet. The link fails when the state file exists, so a
  # write never replaces a saved key, also when two pairings of one name run
  # at the same time.
  defp write_file(dir, name, path, data) do
    tmp = Path.join(dir, ".#{name}.#{System.unique_integer([:positive])}.tmp")

    case File.open(tmp, [:write, :exclusive, :binary]) do
      {:ok, device} ->
        result =
          try do
            with :ok <- File.chmod(tmp, 0o600), do: IO.binwrite(device, data)
          after
            File.close(device)
          end

        case result do
          :ok -> place(tmp, path)
          {:error, reason} -> remove(tmp, reason)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp place(tmp, path) do
    result = File.ln(tmp, path)
    _ = File.rm(tmp)

    case result do
      :ok -> :ok
      {:error, :eexist} -> {:error, :exists}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove(tmp, reason) do
    _ = File.rm(tmp)
    {:error, reason}
  end
end
