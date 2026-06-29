defmodule HotspotWeb.HotspotLive.Picker do
  @moduledoc """
  Server-side repository picker and the background-extraction banner.

  A native browser folder dialog cannot hand the server a real filesystem path, so
  the picker browses the server's filesystem, confined to a root it cannot navigate
  above.
  """
  use HotspotWeb, :html

  attr(:dir, :string, required: true)
  attr(:root, :string, required: true)
  attr(:entries, :list, required: true)

  def repo_picker(assigns) do
    ~H"""
    <div class="fixed inset-0 z-40 flex items-center justify-center bg-black/40">
      <div
        class="bg-base-100 rounded-lg shadow-xl w-[34rem] max-w-[92vw] h-[32rem] max-h-[85vh] flex flex-col"
        phx-click-away="close_picker"
      >
        <div class="flex items-center justify-between px-4 py-3 border-b border-base-300">
          <span class="font-semibold">Open repository</span>
          <button type="button" phx-click="close_picker" class="btn btn-xs btn-ghost">
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>

        <div class="px-4 py-2 border-b border-base-300 flex items-center gap-2 text-xs">
          <button
            type="button"
            phx-click="picker_nav"
            phx-value-path={Path.dirname(@dir)}
            disabled={@dir == @root}
            class="btn btn-xs btn-ghost"
            title="Up"
          >
            <.icon name="hero-arrow-up" class="size-4" />
          </button>
          <span class="font-mono truncate opacity-70">{@dir}</span>
        </div>

        <ul class="overflow-y-auto grow p-2 space-y-0.5">
          <li :if={@entries == []} class="text-sm opacity-60 px-2 py-1">No subdirectories.</li>
          <li :for={e <- @entries}>
            <div class="flex items-center gap-1">
              <button
                type="button"
                phx-click="picker_nav"
                phx-value-path={e.path}
                class="grow text-left flex items-center gap-2 px-2 py-1 rounded hover:bg-base-200 min-w-0"
              >
                <.icon
                  name={if e.is_repo, do: "hero-folder-open", else: "hero-folder"}
                  class={["size-4 shrink-0", e.is_repo && "text-primary"]}
                />
                <span class="font-mono text-sm truncate">{e.name}</span>
              </button>
              <button
                :if={e.is_repo}
                type="button"
                phx-click="pick_repo"
                phx-value-path={e.path}
                class="btn btn-xs btn-primary shrink-0"
              >
                Extract
              </button>
            </div>
          </li>
        </ul>

        <div class="px-4 py-2 border-t border-base-300 text-xs opacity-60">
          Folders with a <code class="font-mono">.git</code>
          are marked; click <span class="font-semibold">Extract</span>
          to analyze.
        </div>
      </div>
    </div>
    """
  end

  attr(:extraction, :map, required: true)

  def extraction_banner(assigns) do
    ~H"""
    <div class="absolute top-3 left-1/2 -translate-x-1/2 z-30 w-[28rem] max-w-[90vw]">
      <div class={[
        "alert shadow-lg flex items-center gap-3 py-2",
        @extraction.state == :error && "alert-error",
        @extraction.state == :done && "alert-success"
      ]}>
        <span :if={@extraction.state == :running} class="loading loading-spinner loading-sm" />
        <div class="text-sm grow min-w-0">
          <%= case @extraction.state do %>
            <% :running -> %>
              <span class="truncate">
                Extracting <span class="font-mono">{Path.basename(@extraction.repo || "")}</span>…
                <span :if={@extraction.commits > 0}>{@extraction.commits} commits</span>
              </span>
            <% :done -> %>
              Extracted <span class="font-mono">{Path.basename(@extraction.repo || "")}</span>
              ({@extraction.commits} commits).
            <% :error -> %>
              Extraction failed: {@extraction.reason}
          <% end %>
        </div>
        <button
          :if={@extraction.state != :running}
          type="button"
          phx-click="dismiss_extraction"
          class="btn btn-xs btn-ghost"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  @doc "Root the picker is confined to (no navigating above it). Defaults to `$HOME`."
  def repo_root do
    Application.get_env(:hotspot_web, :repo_root) || System.user_home!()
  end

  @doc "Whether `path` is `root` or sits beneath it, after expansion."
  def within_root?(path, root) do
    path = Path.expand(path)
    path == root or String.starts_with?(path <> "/", root <> "/")
  end

  @doc """
  Immediate subdirectories of `dir` (skipping hidden ones), each flagged for whether
  it is itself a git repo. Returns `[]` when `dir` cannot be listed.
  """
  def list_dirs(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.sort()
        |> Enum.map(fn p ->
          %{name: Path.basename(p), path: p, is_repo: File.dir?(Path.join(p, ".git"))}
        end)

      {:error, _} ->
        []
    end
  end
end
