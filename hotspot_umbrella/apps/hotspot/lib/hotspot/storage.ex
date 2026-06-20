defmodule Hotspot.Storage do
  @moduledoc """
  Owns the storage *lifecycle*: which runner-produced `.db` files are available,
  which one is currently open, and the `Hotspot.Repo` connection pool over it.

  No db is wired in at boot: the app starts with nothing open and a file is
  selected at runtime, like DB Browser for SQLite's "Open Database".
  This GenServer is a lifecycle manager, not a query proxy: reads still go through
  Ecto (`Hotspot.Analysis` -> `Hotspot.Repo`); it just starts/stops the pool under
  `Hotspot.RepoSupervisor` and tracks the selection.

  Available files are discovered in the directory configured as
  `config :hotspot, :db_dir` (env `HOTSPOT_DB_DIR`). State changes are broadcast on
  `Hotspot.PubSub` topic `"storage"` so LiveViews can swap between picker and view.
  """
  use GenServer

  require Logger

  @topic "storage"
  @repo Hotspot.Repo
  @repo_sup Hotspot.RepoSupervisor

  ## Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "PubSub topic broadcasting `{:storage_changed, current_path | nil}`."
  def topic, do: @topic

  @doc "Available `.db` files in the configured directory, sorted by name."
  @spec list() :: [%{name: String.t(), path: String.t(), size: non_neg_integer()}]
  def list, do: GenServer.call(__MODULE__, :list)

  @doc "Absolute path of the currently open db, or `nil`."
  @spec current() :: String.t() | nil
  def current, do: GenServer.call(__MODULE__, :current)

  @doc "Whether a db is currently open (the pool is running)."
  @spec loaded?() :: boolean()
  def loaded?, do: current() != nil

  @doc """
  Open `path` (must be a `.db` inside the configured directory). Restarts the pool
  if one is already open. Returns `:ok` or `{:error, reason}`.
  """
  @spec open(String.t()) :: :ok | {:error, term()}
  def open(path), do: GenServer.call(__MODULE__, {:open, path})

  @doc "Close the current db and tear down the pool."
  @spec close() :: :ok
  def close, do: GenServer.call(__MODULE__, :close)

  ## Server callbacks

  @impl true
  def init(opts) do
    dir = Keyword.get(opts, :dir) || Application.get_env(:hotspot, :db_dir) || File.cwd!()
    {:ok, %{dir: Path.expand(dir), current: nil, pool: nil}}
  end

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, scan(state.dir), state}
  end

  def handle_call(:current, _from, state) do
    {:reply, state.current, state}
  end

  def handle_call({:open, path}, _from, state) do
    path = Path.expand(path)

    with :ok <- validate(path, state.dir),
         state <- stop_pool(state),
         {:ok, pid} <- start_pool(path) do
      state = %{state | current: path, pool: pid}
      broadcast(path)
      {:reply, :ok, state}
    else
      {:error, reason} = error ->
        Logger.warning("Hotspot.Storage.open failed for #{path}: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  def handle_call(:close, _from, state) do
    state = %{stop_pool(state) | current: nil}
    broadcast(nil)
    {:reply, :ok, state}
  end

  ## Internals

  defp scan(dir) do
    dir
    |> Path.join("*.db")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      size =
        case File.stat(path) do
          {:ok, %{size: size}} -> size
          _ -> 0
        end

      %{name: Path.basename(path), path: path, size: size}
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp validate(path, dir) do
    cond do
      Path.dirname(path) != dir -> {:error, :outside_db_dir}
      Path.extname(path) != ".db" -> {:error, :not_a_db}
      not File.regular?(path) -> {:error, :not_found}
      true -> :ok
    end
  end

  defp start_pool(path) do
    spec = {@repo, database: path, mode: :readonly, pool_size: 5}
    DynamicSupervisor.start_child(@repo_sup, spec)
  end

  defp stop_pool(%{pool: nil} = state), do: state

  defp stop_pool(%{pool: pid} = state) do
    DynamicSupervisor.terminate_child(@repo_sup, pid)
    %{state | pool: nil}
  end

  defp broadcast(current) do
    Phoenix.PubSub.broadcast(Hotspot.PubSub, @topic, {:storage_changed, current})
  end
end
