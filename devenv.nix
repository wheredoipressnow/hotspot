{
  pkgs,
  lib,
  config,
  inputs,
  ...
}:

let
  pkgs-unstable = import inputs.nixpkgs-unstable { system = pkgs.stdenv.system; };
in
{
  packages = [
    pkgs.git
    pkgs.sqlite
    pkgs.inotify-tools
    pkgs.tailwindcss-language-server
    pkgs.tailwindcss_4
    pkgs.nodejs
    pkgs.vscode-langservers-extracted
    pkgs.prettier
    inputs.expert.packages.${pkgs.system}.default
  ];

  languages = {
    javascript = {
      enable = true;
      package = pkgs.nodejs_22;
      pnpm.enable = true;
    };
    typescript.enable = true;
    elixir = {
      enable = true;
      package = pkgs-unstable.beam29Packages.elixir_1_20;
    };
  };

  env.TAILWINDCSS_PATH = "${pkgs.lib.getExe pkgs.tailwindcss_4}";

  git-hooks.hooks.mix-format.enable = true;

  # See full reference at https://devenv.sh/reference/options/
}
