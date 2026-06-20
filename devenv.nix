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
    pkgs.ormolu
    pkgs.biome
    pkgs.inotify-tools
    pkgs.tailwindcss-language-server
    pkgs.tailwindcss_4
    pkgs.nodejs
    pkgs.vscode-langservers-extracted
    pkgs.prettier
    inputs.expert.packages.${pkgs.system}.default
  ];

  languages.javascript = {
    enable = true;
    package = pkgs.nodejs_22;
    pnpm.enable = true;
  };
  languages.typescript.enable = true;

  languages.haskell.enable = true;

  languages.elixir.enable = true;
  languages.elixir.package = pkgs-unstable.beam29Packages.elixir_1_20;

  env.TAILWINDCSS_PATH = "${pkgs.lib.getExe pkgs.tailwindcss_4}";

  git-hooks.hooks.mix-format.enable = true;

  scripts.fmt-hs.exec = ''
    files=$(git ls-files '*.hs')
    if [ -n "$files" ]; then
      ormolu --mode inplace $files
    else
      echo "fmt-hs: no .hs files yet"
    fi
  '';

  # See full reference at https://devenv.sh/reference/options/
}
