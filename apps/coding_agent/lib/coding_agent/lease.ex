defmodule CodingAgent.Lease do
  @moduledoc """
  The lease that a running VM holds on its build.

  A release VM takes a marker in its build folder, `<build>/.helyx-lease-<os
  pid>`, at its start, and removes it at a clean end. `mix helyx.install` keeps
  a build that has the marker of a live pid, so the modules of a running
  session stay in place (ADR 0014, invariant 4; `docs/features/local-release.md`).

  Only a release takes a lease: its release script sets `RELEASE_ROOT` and
  `RELEASE_VSN`, and `mix helyx` sets neither.
  """

  # The build takes one marker for each VM, so that two VMs of one build do
  # not overwrite or remove each other's lease.
  @prefix ".helyx-lease-"

  @typedoc "The lease of a VM: its marker path, or `:none` outside a release."
  @type t :: :none | Path.t()

  @doc """
  Takes the lease of this VM in the release of `env`, and returns its marker
  path, or `:none` outside a release. Returns `{:error, text}` when the
  marker cannot be written: a VM that cannot hold its lease does not run.
  """
  @spec acquire(%{String.t() => String.t()}) :: {:ok, t()} | {:error, String.t()}
  def acquire(env) do
    case {env["RELEASE_ROOT"], env["RELEASE_VSN"]} do
      {root, vsn} when is_binary(root) and root != "" and is_binary(vsn) and vsn != "" ->
        write(root)

      _ ->
        {:ok, :none}
    end
  end

  @doc "Removes the marker of `lease`. A failed removal leaves a stale marker."
  @spec release(t()) :: :ok
  def release(:none), do: :ok

  def release(path) do
    _ = File.rm(path)
    :ok
  end

  @doc """
  Tells whether a VM holds a build: it has a marker whose pid is live.
  """
  @spec held?(Path.t()) :: boolean()
  def held?(build) do
    with {:ok, %File.Stat{type: :directory}} <- File.lstat(build),
         {:ok, entries} <- File.ls(build) do
      Enum.any?(entries, &live_marker?/1)
    else
      _ -> false
    end
  end

  @doc "The name of the marker of the OS process `pid`, default this VM."
  @spec marker_name(String.t() | integer()) :: String.t()
  def marker_name(pid \\ System.pid()), do: @prefix <> to_string(pid)

  defp write(root) do
    path = Path.join(root, marker_name())

    case File.write(path, "#{System.pid()} #{Path.basename(root)}\n") do
      :ok ->
        {:ok, path}

      {:error, reason} ->
        {:error, "could not write the build lease #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp live_marker?(@prefix <> pid) do
    case Integer.parse(pid) do
      {pid, ""} when pid > 0 -> live?(pid)
      _ -> false
    end
  end

  defp live_marker?(_entry), do: false

  # Signal 0 checks for the process and sends nothing. A pid of another user
  # answers EPERM, so the marker reads as stale; a build of the install has
  # the user's pids.
  defp live?(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end
end
