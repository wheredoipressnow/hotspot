defmodule HotspotWeb.HotspotLiveTest do
  use HotspotWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Hotspot.Storage

  defp reopen_fixture do
    case Storage.list() do
      [%{path: path} | _] -> Storage.open(path)
      [] -> :ok
    end
  end

  test "with a db loaded, renders the hotspots view with the top bar and panels", %{conn: conn} do
    reopen_fixture()

    {:ok, _view, html} = live(conn, ~p"/")
    # Top bar (repo management + global time range) and the docked panels.
    assert html =~ "Open repository"
    assert html =~ "All time"
    assert html =~ "Top hotspots"
    assert html =~ ~s(phx-hook="CirclePack")
  end

  test "with no db loaded, renders the database picker", %{conn: conn} do
    Storage.close()
    on_exit(&reopen_fixture/0)

    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "Open a database"
    refute html =~ ~s(phx-hook="CirclePack")

    # Picking a db reveals the chart without a reconnect.
    [%{path: path} | _] = Storage.list()
    render_click(view, "open_db", %{"db" => path})
    assert render(view) =~ ~s(phx-hook="CirclePack")
  end

  describe "repository picker" do
    setup do
      # An isolated tree: a repo (has .git) and a plain directory, under a root.
      root = Path.join(System.tmp_dir!(), "hotspot_picker_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join([root, "myrepo", ".git"]))
      File.mkdir_p!(Path.join(root, "plain"))
      prev = Application.get_env(:hotspot_web, :repo_root)
      Application.put_env(:hotspot_web, :repo_root, root)

      on_exit(fn ->
        File.rm_rf!(root)

        if prev,
          do: Application.put_env(:hotspot_web, :repo_root, prev),
          else: Application.delete_env(:hotspot_web, :repo_root)
      end)

      %{root: root}
    end

    test "lists subdirectories and flags git repos", %{conn: conn, root: root} do
      {:ok, view, _html} = live(conn, ~p"/")
      html = render_click(view, "open_picker", %{})

      assert html =~ "myrepo"
      assert html =~ "plain"
      # Only the repo offers an Extract action.
      assert html =~ "Extract"
      assert html =~ ~s(phx-value-path="#{Path.join(root, "myrepo")}")
    end

    test "rejects a directory without a .git", %{conn: conn, root: root} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "open_picker", %{})
      html = render_click(view, "pick_repo", %{"path" => Path.join(root, "plain")})

      assert html =~ "Not a git repository"
    end

    test "navigation cannot escape the configured root", %{conn: conn, root: root} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "open_picker", %{})

      # Attempt to navigate above the root; the displayed dir must stay at root
      # and keep listing root's entries.
      html = render_click(view, "picker_nav", %{"path" => Path.dirname(root)})
      assert html =~ root
      assert html =~ "myrepo"
    end
  end
end
