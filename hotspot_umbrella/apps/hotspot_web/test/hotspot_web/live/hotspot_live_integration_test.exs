defmodule HotspotWeb.HotspotLiveIntegrationTest do
  # Opt-in (`:integration`); run with `mix test --include integration`.
  use HotspotWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Exqlite.Sqlite3
  alias HotspotRunner.Writer

  @moduletag :integration

  setup do
    prev_repo = Application.get_env(:hotspot, :repo)
    prev_storage = Application.get_env(:hotspot, :storage)
    Application.put_env(:hotspot, :repo, Hotspot.Repo)
    Application.put_env(:hotspot, :storage, Hotspot.Storage)

    path = seed_db()

    on_exit(fn ->
      Hotspot.Storage.close()
      for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix)
      restore(:repo, prev_repo)
      restore(:storage, prev_storage)
    end)

    %{path: path}
  end

  test "with a db loaded, renders the hotspots view with the top bar and panels", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    # Top bar (repo management + global time range) and the docked panels.
    assert html =~ "Open repository"
    assert html =~ "All time"
    assert html =~ "Top hotspots"
    assert html =~ ~s(phx-hook="CirclePack")
  end

  test "picking a db reveals the chart without a reconnect", %{conn: conn, path: path} do
    Hotspot.Storage.close()

    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "Open a database"
    refute html =~ ~s(phx-hook="CirclePack")

    render_click(view, "open_db", %{"db" => path})
    assert render(view) =~ ~s(phx-hook="CirclePack")
  end

  # Build a tiny real db through the writer, then checkpoint the WAL into the main
  # file so the read-only pool can open it. Returns the path (inside :db_dir, the
  # only directory Storage will open).
  defp seed_db do
    dir = Application.fetch_env!(:hotspot, :db_dir)
    File.mkdir_p!(dir)
    path = Path.join(dir, "web_seed_#{System.unique_integer([:positive])}.db")
    now = System.os_time(:second)

    w = Writer.open(path)

    Writer.write_batch(w, [
      %{
        sha: "c1",
        committed_at: now,
        author_name: "Ada",
        author_email: "ada@x",
        parent_count: 1,
        subject: "first",
        files: [%{path: "lib/a.ex", added: 10, deleted: 0}],
        renames: []
      }
    ])

    Writer.replace_tracked_files(
      w,
      [%{path: "lib/a.ex", loc: 5, indent_total: 2, indent_max: 1}],
      "c1"
    )

    Writer.close(w)
    checkpoint(path)

    :ok = Hotspot.Storage.open(path)
    path
  end

  defp checkpoint(path) do
    {:ok, conn} = Sqlite3.open(path)
    :ok = Sqlite3.execute(conn, "PRAGMA wal_checkpoint(TRUNCATE);")
    :ok = Sqlite3.close(conn)
  end

  defp restore(key, nil), do: Application.delete_env(:hotspot, key)
  defp restore(key, value), do: Application.put_env(:hotspot, key, value)
end
