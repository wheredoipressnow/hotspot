defmodule HotspotWeb.HotspotLive.Palette do
  @moduledoc """
  Command palette (fuzzy finder) over the repo's file and folder index. Selecting a
  file opens its X-Ray, a folder sets the scope, the same grammar as a map click.
  """
  use HotspotWeb, :html

  @palette_limit 50

  attr(:query, :string, required: true)
  attr(:results, :list, required: true)

  def command_palette(assigns) do
    ~H"""
    <div
      class="fixed inset-0 z-50 flex items-start justify-center pt-[12vh] bg-black/40"
      phx-window-keydown="close_palette"
      phx-key="Escape"
    >
      <div
        class="bg-base-100 rounded-lg shadow-xl w-[36rem] max-w-[92vw] max-h-[70vh] flex flex-col"
        phx-click-away="close_palette"
      >
        <form phx-change="palette_search" class="p-2 border-b border-base-300">
          <input
            type="text"
            name="q"
            value={@query}
            autocomplete="off"
            autofocus
            phx-debounce="80"
            placeholder="Go to file or folder…"
            class="input input-bordered input-sm w-full"
          />
        </form>

        <ul class="overflow-y-auto p-1">
          <li :if={@results == []} class="px-3 py-2 text-sm opacity-60">No matches.</li>
          <li :for={e <- @results}>
            <button
              type="button"
              phx-click="palette_select"
              phx-value-path={e.path}
              phx-value-kind={Atom.to_string(e.kind)}
              class="w-full text-left flex items-center gap-2 px-3 py-1.5 rounded hover:bg-base-200"
            >
              <.icon
                name={if e.kind == :folder, do: "hero-folder", else: "hero-document"}
                class="size-4 shrink-0 opacity-60"
              />
              <span class="font-mono text-sm truncate">{e.path}</span>
              <span :if={e.kind == :folder} class="ml-auto text-[11px] opacity-40 shrink-0">
                folder
              </span>
            </button>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  @doc """
  Ranks index entries against the query. An empty query shows the first entries; a
  substring match ranks above a looser subsequence match; ties break on path length.
  Caps the result at #{@palette_limit} entries.
  """
  def filter(index, query) do
    case String.trim(query) do
      "" ->
        Enum.take(index, @palette_limit)

      q ->
        q = String.downcase(q)

        index
        |> Enum.flat_map(fn e ->
          case fuzzy_score(String.downcase(e.path), q) do
            nil -> []
            score -> [{score, e}]
          end
        end)
        |> Enum.sort_by(fn {score, e} -> {score, String.length(e.path)} end)
        |> Enum.take(@palette_limit)
        |> Enum.map(&elem(&1, 1))
    end
  end

  # Lower is better: a substring match (ranked by its position) beats a subsequence
  # match; `nil` when the query is not even a subsequence.
  defp fuzzy_score(path, q) do
    case :binary.match(path, q) do
      {pos, _} -> {0, pos}
      :nomatch -> if subsequence?(path, q), do: {1, 0}, else: nil
    end
  end

  defp subsequence?(_path, ""), do: true
  defp subsequence?("", _q), do: false

  defp subsequence?(<<ch::utf8, prest::binary>>, <<ch::utf8, qrest::binary>>),
    do: subsequence?(prest, qrest)

  defp subsequence?(<<_::utf8, prest::binary>>, q), do: subsequence?(prest, q)
end
