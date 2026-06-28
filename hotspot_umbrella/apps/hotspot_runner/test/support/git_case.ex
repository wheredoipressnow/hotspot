defmodule HotspotRunner.GitCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :git

      import HotspotRunner.GitCase
    end
  end

  setup do
    prev_git = Application.get_env(:hotspot_runner, :git)
    prev_store = Application.get_env(:hotspot_runner, :store)
    Application.put_env(:hotspot_runner, :git, HotspotRunner.Git)
    Application.put_env(:hotspot_runner, :store, HotspotRunner.Writer)

    on_exit(fn ->
      restore(:git, prev_git)
      restore(:store, prev_store)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:hotspot_runner, key)
  defp restore(key, value), do: Application.put_env(:hotspot_runner, key, value)
end
