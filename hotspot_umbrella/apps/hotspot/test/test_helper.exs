ExUnit.start()

# No db is opened at boot. Open the first runner-produced fixture in `:db_dir` so
# the read-only Analysis tests have a db (read-only Repo, no SQL Sandbox).
case Hotspot.Storage.list() do
  [%{path: path} | _] -> Hotspot.Storage.open(path)
  [] -> raise "no fixture .db found in #{Application.get_env(:hotspot, :db_dir)}"
end
