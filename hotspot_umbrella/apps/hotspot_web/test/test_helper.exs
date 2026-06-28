# Opt-in tests are excluded by default; run them with `mix test --include integration`.
ExUnit.start(exclude: [:integration])

Mox.defmock(Hotspot.RepoMock, for: Hotspot.ReadRepo)
Mox.defmock(Hotspot.StorageMock, for: Hotspot.Storage.Behaviour)
