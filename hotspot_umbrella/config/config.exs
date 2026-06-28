import Config

config :hotspot,
  ecto_repos: [Hotspot.Repo],
  recency_half_life_days: 90

config :hotspot_web,
  ecto_repos: [Hotspot.Repo],
  generators: [context_app: :hotspot]

config :hotspot_web, HotspotWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: HotspotWeb.ErrorHTML, json: HotspotWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Hotspot.PubSub,
  live_view: [signing_salt: "o3YPS3lY"]

config :esbuild,
  version: "0.25.4",
  path: Path.expand("../apps/hotspot_web/assets/node_modules/.bin/esbuild", __DIR__),
  hotspot_web: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../apps/hotspot_web/assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :tailwind,
  version: "4.3.0",
  path: System.get_env("TAILWINDCSS_PATH"),
  hotspot_web: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("../apps/hotspot_web", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"

config :phoenix_live_view,
  root_tag_attribute: "phx-r"
