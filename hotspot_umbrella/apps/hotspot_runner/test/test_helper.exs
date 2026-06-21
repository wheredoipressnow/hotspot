# Tests tagged `:git` build throwaway repos and require the `git` binary. They
# are excluded by default so CI stays green without git; run them explicitly with
# `mix test --include git`.
ExUnit.start(exclude: [:git])
