import Config

# Read-only Ecto in tests too: the schema is owned by the git runner, so there is
# no Sandbox/ownership — tests run against a real runner-produced fixture db.
# `:db_dir` holds the runner's dbs; the test helpers open one via Hotspot.Storage.
config :hotspot, :db_dir, System.get_env("HOTSPOT_DB_DIR") || Path.expand("../../dbs", __DIR__)

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :hotspot_web, HotspotWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "qp+VVYoWr2hsJcbgOpchb1RX716KPRY0B48aAA1SdMoVQVtiSlfcvngjghT0pC8E",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
