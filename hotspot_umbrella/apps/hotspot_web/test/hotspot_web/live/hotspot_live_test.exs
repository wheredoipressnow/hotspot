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

  test "with a db loaded, renders the hotspots view with controls", %{conn: conn} do
    reopen_fixture()

    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Hotspots"
    assert html =~ "Path filter"
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
end
