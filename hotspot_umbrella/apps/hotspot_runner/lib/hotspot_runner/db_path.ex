defmodule HotspotRunner.DbPath do
  @moduledoc """
  Resolves the SQLite file for a repo: one db per repo under the shared db
  directory, named after the repo with a short hash of its top-level path for
  uniqueness (`<basename>-<hash>.db`).

  The directory is `config :hotspot, :db_dir` (the same value `Hotspot.Storage`
  reads), falling back to `$XDG_DATA_HOME/hotspot`. Resolving both from one place
  is what lets a freshly written db be discovered and opened by the web app.
  """

  @doc "The directory holding all per-repo databases."
  @spec dir() :: String.t()
  def dir do
    Application.get_env(:hotspot, :db_dir) ||
      Path.join(System.get_env("XDG_DATA_HOME") || Path.expand("~/.local/share"), "hotspot")
  end

  @doc """
  Absolute path of the db for a repo identified by its top-level directory.
  Creates the containing directory if needed. The same `toplevel` always maps to
  the same file, so re-extraction is incremental.
  """
  @spec path(String.t()) :: String.t()
  def path(toplevel) do
    File.mkdir_p!(dir())
    file_path(toplevel)
  end

  @doc "Absolute db path for `toplevel` without creating the directory, unlike `path/1`."
  @spec file_path(String.t()) :: String.t()
  def file_path(toplevel) do
    Path.join(dir(), "#{name(toplevel)}-#{short_hash(toplevel)}.db")
  end

  defp name(toplevel) do
    case Path.basename(toplevel) do
      "" -> "repo"
      base -> String.replace(base, ~r/[^A-Za-z0-9._-]/, "-")
    end
  end

  defp short_hash(toplevel) do
    :crypto.hash(:sha256, toplevel) |> Base.encode16(case: :lower) |> binary_part(0, 8)
  end
end
