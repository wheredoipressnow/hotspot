defmodule HotspotWeb.HotspotLiveTest do
  use HotspotWeb.ConnCase

  import Phoenix.LiveViewTest
  import Mox

  # The LiveView runs in its own process, so the mock must be reachable from any
  # process (requires async: false, which ConnCase already is).
  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    # mount/3 only consults storage availability; with nothing open every
    # Analysis read short-circuits before reaching the repo.
    Hotspot.StorageMock
    |> stub(:topic, fn -> "storage" end)
    |> stub(:list, fn -> [] end)
    |> stub(:current, fn -> nil end)
    |> stub(:loaded?, fn -> false end)

    :ok
  end

  test "with no db loaded, renders the database picker", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Open a database"
    refute html =~ ~s(phx-hook="CirclePack")
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
