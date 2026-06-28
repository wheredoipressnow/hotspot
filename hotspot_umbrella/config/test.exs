import Config

config :hotspot,
  repo: Hotspot.RepoMock,
  storage: Hotspot.StorageMock

config :hotspot_runner,
  git: HotspotRunner.GitMock,
  store: HotspotRunner.StoreMock

config :hotspot, :db_dir, Path.join(System.tmp_dir!(), "hotspot_test_dbs")

config :hotspot_web, HotspotWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "qp+VVYoWr2hsJcbgOpchb1RX716KPRY0B48aAA1SdMoVQVtiSlfcvngjghT0pC8E",
  server: false

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  enable_expensive_runtime_checks: true

config :phoenix,
  sort_verified_routes_query_params: true
