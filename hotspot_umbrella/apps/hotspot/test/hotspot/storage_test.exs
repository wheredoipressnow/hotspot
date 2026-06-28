defmodule Hotspot.StorageTest do
  use Hotspot.IntegrationCase

  alias Hotspot.{Analysis, Storage}

  setup do
    seed_coupling_repo!()
    :ok
  end

  test "list/0 returns the .db files in the configured dir" do
    dbs = Storage.list()
    assert dbs != []
    assert Enum.all?(dbs, &String.ends_with?(&1.path, ".db"))
    assert Enum.all?(dbs, &(&1.size > 0))
  end

  test "open/1 makes the db loaded and queryable" do
    [%{path: path} | _] = Storage.list()

    assert :ok = Storage.open(path)
    assert Storage.loaded?()
    assert Storage.current() == path
    assert %{commits: commits} = Analysis.repo_stats()
    assert commits > 0
  end

  test "close/0 unloads the db and reads report no_database" do
    [%{path: path} | _] = Storage.list()
    Storage.open(path)

    assert :ok = Storage.close()
    refute Storage.loaded?()
    assert {:error, :no_database} = Analysis.repo_stats()
    assert {:error, :no_database} = Analysis.tree_for_visualization(%{})
  end

  test "open/1 rejects paths outside the configured dir" do
    assert {:error, :outside_db_dir} = Storage.open("/etc/passwd.db")
  end
end
