defmodule Hotspot.StorageTest do
  @moduledoc """
  Exercises the storage lifecycle against the real fixture dir. Not async — it
  opens/closes the singleton Repo pool, so it must not overlap analysis_test.
  Each test restores the globally-open fixture so the rest of the suite is unaffected.
  """
  use ExUnit.Case, async: false

  alias Hotspot.{Analysis, Storage}

  setup do
    on_exit(fn ->
      # Restore the fixture opened in test_helper.exs.
      case Storage.list() do
        [%{path: path} | _] -> Storage.open(path)
        [] -> :ok
      end
    end)
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
