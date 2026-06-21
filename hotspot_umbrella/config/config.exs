# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
import Config

# Configure Mix tasks and generators
config :hotspot,
  ecto_repos: [Hotspot.Repo],
  # Half-life (days) for recency-weighted churn: a change this old counts half as
  # much as one made now. See Hotspot.Analysis.Recency.
  recency_half_life_days: 90

config :hotspot_web,
  ecto_repos: [Hotspot.Repo],
  generators: [context_app: :hotspot]

# Configures the endpoint
config :hotspot_web, HotspotWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: HotspotWeb.ErrorHTML, json: HotspotWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Hotspot.PubSub,
  live_view: [signing_salt: "o3YPS3lY"]

# Configure esbuild. On NixOS the auto-downloaded esbuild is a generic dynamically
# linked binary that won't run, so use the one installed under assets/node_modules.
config :esbuild,
  version: "0.25.4",
  path: Path.expand("../apps/hotspot_web/assets/node_modules/.bin/esbuild", __DIR__),
  hotspot_web: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../apps/hotspot_web/assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind. Use the nix-provided binary (TAILWINDCSS_PATH from devenv)
# instead of the auto-downloaded one, which won't run on NixOS.
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

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"
