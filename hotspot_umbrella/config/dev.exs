import Config

config :hotspot,
       :db_dir,
       (System.get_env("HOTSPOT_DB_DIR") ||
          Path.join(System.get_env("XDG_DATA_HOME") || Path.expand("~/.local/share"), "hotspot"))
       |> Path.expand(Path.expand("..", __DIR__))

config :hotspot, Hotspot.Repo,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

config :hotspot_web, HotspotWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "jmSDy7tzgoTC71wflCuHq9qm0T3j9aiOElBYOh5dU/7pDMinIs7RV2/8OyziekQy",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:hotspot_web, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:hotspot_web, ~w(--watch)]}
  ]

config :hotspot_web, HotspotWeb.Endpoint,
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*\.po$",
      ~r"lib/hotspot_web/router\.ex$",
      ~r"lib/hotspot_web/(controllers|live|components)/.*\.(ex|heex)$"
    ]
  ]

config :hotspot_web, dev_routes: true

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true,
  enable_expensive_runtime_checks: true

config :phoenix, :stacktrace_depth, 20
