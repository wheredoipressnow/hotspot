defmodule Hotspot.Repo do
  use Ecto.Repo,
    otp_app: :hotspot,
    adapter: Ecto.Adapters.SQLite3
end
