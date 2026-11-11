defmodule Helyx.Hub.Store.SQLite.Disk do
  @moduledoc false
  # The store file of the SQLite store and the files that SQLite keeps beside
  # it (docs/features/hub.md, decision 9: `check/1`, `create/1`, and `own/1`
  # are its three steps on the disk).

  @sidecars ["-wal", "-shm", "-journal"]
  # The second name of a new file lives from its link to the removal of the
  # private folder, a few file operations.
  @link_wait_ms 100
  @link_poll_ms 5

  @doc false
  @spec check(Path.t()) :: :ok | :missing | {:error, {:invalid_option, :path}}
  def check(path) do
    with :ok <- sidecars(path) do
      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular}} -> :ok
        {:error, :enoent} -> :missing
        _ -> invalid()
      end
    end
  end

  defp sidecars(path) do
    Enum.reduce_while(@sidecars, :ok, fn suffix, :ok ->
      case File.lstat(path <> suffix) do
        {:ok, %File.Stat{type: :regular, links: 1}} -> {:cont, :ok}
        {:error, :enoent} -> {:cont, :ok}
        _ -> {:halt, invalid()}
      end
    end)
  end

  @doc false
  # :ok also when another start linked its file into place first: the lock
  # decides between the two.
  @spec create(Path.t()) :: :ok | {:error, {:invalid_option, :path}}
  def create(path) do
    private =
      Path.join(Path.dirname(path), ".hub-" <> Base.url_encode64(:crypto.strong_rand_bytes(9)))

    file = Path.join(private, "hub.db")

    try do
      with :ok <- File.mkdir(private),
           # Only the owner of the folder can chmod it, so a chmod that
           # succeeds shows that the server owns it.
           :ok <- File.chmod(private, 0o700),
           :ok <- private?(private),
           :ok <- File.touch(file),
           :ok <- File.chmod(file, 0o600) do
        link(file, path)
      else
        _ -> invalid()
      end
    after
      File.rm_rf(private)
    end
  end

  defp private?(folder) do
    with {:ok, %File.Stat{type: :directory, mode: mode}} <- File.lstat(folder),
         true <- Bitwise.band(mode, 0o777) == 0o700,
         {:ok, []} <- File.ls(folder) do
      :ok
    else
      _ -> invalid()
    end
  end

  defp link(file, path) do
    case File.ln(file, path) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      {:error, _} -> invalid()
    end
  end

  @doc false
  @spec own(Path.t()) :: :ok | {:error, {:invalid_option, :path}}
  def own(path) do
    with :ok <- one_name(path, System.monotonic_time(:millisecond) + @link_wait_ms),
         do: chmod_all(path)
  end

  defp one_name(path, until) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, links: 1}} ->
        :ok

      {:ok, %File.Stat{type: :regular} = stat} ->
        if System.monotonic_time(:millisecond) < until do
          Process.sleep(@link_poll_ms)
          one_name(path, until)
        else
          left_create(path, stat)
        end

      _ ->
        invalid()
    end
  end

  # The other name of the file in a private folder of a create; any other
  # second name refuses the start.
  defp left_create(path, stat) do
    dir = Path.dirname(path)

    with {:ok, names} <- File.ls(dir),
         [_ | _] = folders <-
           Enum.filter(
             names,
             &(String.starts_with?(&1, ".hub-") and same?(Path.join([dir, &1, "hub.db"]), stat))
           ) do
      Enum.each(folders, &File.rm_rf(Path.join(dir, &1)))
      one_name(path, System.monotonic_time(:millisecond))
    else
      _ -> invalid()
    end
  end

  defp same?(name, %File.Stat{inode: inode, major_device: device}) do
    match?(
      {:ok, %File.Stat{type: :regular, inode: ^inode, major_device: ^device}},
      File.lstat(name)
    )
  end

  defp chmod_all(path) do
    Enum.reduce_while(["" | @sidecars], :ok, fn suffix, :ok ->
      case File.chmod(path <> suffix, 0o600) do
        :ok -> {:cont, :ok}
        {:error, :enoent} -> {:cont, :ok}
        {:error, _} -> {:halt, invalid()}
      end
    end)
  end

  defp invalid, do: {:error, {:invalid_option, :path}}
end
