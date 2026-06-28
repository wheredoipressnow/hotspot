# Opt-in tests are excluded by default; run them with `mix test --include git --include integration`.
ExUnit.start(exclude: [:git, :integration])

Mox.defmock(HotspotRunner.GitMock, for: HotspotRunner.Git)
Mox.defmock(HotspotRunner.StoreMock, for: HotspotRunner.Writer)
