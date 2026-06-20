defmodule HotspotWeb.PageController do
  use HotspotWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
