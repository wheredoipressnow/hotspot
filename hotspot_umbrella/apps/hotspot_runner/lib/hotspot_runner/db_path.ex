defmodule HotspotRunner.DbPath do
  @moduledoc """
  Resolves the SQLite file for a repo: one db per repo, keyed by the repo's
  top-level path under the XDG data dir (`$XDG_DATA_HOME/hotspot`, default
  `~/.local/share/hotspot`). Keeps the analyzed repo clean (no stray db file,
  survives `git clean`).

  This directory MUST match the web app's `:db_dir` (`config :hotspot, :db_dir`)
  so `Hotspot.Storage` discovers what the runner writes.
  """

  @doc "The directory holding all per-repo databases."
  @spec dir() :: String.t()
  def dir do
    base = System.get_env("XDG_DATA_HOME") || Path.expand("~/.local/share")
    Path.join(base, "hotspot")
  end

  @doc """
  Absolute path of the db for a repo identified by its top-level directory.
  Creates the containing directory if needed.
  """
  @spec path(String.t()) :: String.t()
  def path(toplevel) do
    d = dir()
    File.mkdir_p!(d)
    hash = :crypto.hash(:sha256, toplevel) |> Base.encode16(case: :lower)
    Path.join(d, hash <> ".db")
  end
end
