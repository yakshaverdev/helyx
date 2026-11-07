defmodule CodingAgent.LeaseTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Lease

  @moduletag :tmp_dir

  # Far above the pid_max of Linux (4,194,304) and of macOS, so no process
  # has it.
  @dead_pid 999_999_999

  test "a release VM takes a marker with its pid and build, and removes it", %{tmp_dir: root} do
    env = %{"RELEASE_ROOT" => root, "RELEASE_VSN" => "0.1.0+abc1234"}

    assert {:ok, path} = Lease.acquire(env)
    assert path == Path.join(root, Lease.marker_name())
    assert File.read!(path) == "#{System.pid()} #{Path.basename(root)}\n"
    assert Lease.held?(root)

    assert :ok = Lease.release(path)
    refute File.exists?(path)
    refute Lease.held?(root)
  end

  test "outside a release there is no marker", %{tmp_dir: root} do
    assert {:ok, :none} = Lease.acquire(%{})
    assert {:ok, :none} = Lease.acquire(%{"RELEASE_ROOT" => root})
    assert {:ok, :none} = Lease.acquire(%{"RELEASE_VSN" => "0.1.0+abc1234"})
    assert File.ls!(root) == []
  end

  test "a dead pid is a stale marker; a live one holds the build", %{tmp_dir: root} do
    File.write!(Path.join(root, Lease.marker_name(@dead_pid)), "#{@dead_pid} x\n")
    refute Lease.held?(root)

    File.write!(Path.join(root, Lease.marker_name()), "#{System.pid()} x\n")
    assert Lease.held?(root)
  end

  test "a name that is not a positive pid is not a lease", %{tmp_dir: root} do
    for name <- [".helyx-lease-x", ".helyx-lease-", ".helyx-lease-0", ".helyx-lease--1"] do
      File.write!(Path.join(root, name), "x\n")
    end

    refute Lease.held?(root)
  end

  test "a build that cannot take a marker reports it", %{tmp_dir: root} do
    env = %{"RELEASE_ROOT" => Path.join(root, "missing"), "RELEASE_VSN" => "0.1.0+abc1234"}
    assert {:error, text} = Lease.acquire(env)
    assert text =~ "could not write the build lease"
  end
end
