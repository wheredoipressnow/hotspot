import Config

config :hotspot_web, HotspotWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() != :test do
  config :hotspot,
         :db_dir,
         (System.get_env("HOTSPOT_DB_DIR") ||
            Path.join(System.get_env("XDG_DATA_HOME") || Path.expand("~/.local/share"), "hotspot"))
         |> Path.expand(Path.expand("..", __DIR__))
end

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  config :hotspot_web, HotspotWeb.Endpoint,
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  config :hotspot, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")
end
