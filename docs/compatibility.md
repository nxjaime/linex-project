# Compatibility

| Upstream app version | Internal build | Linux Mint status | Verified on | Notes |
| --- | ---: | --- | --- | --- |
| 26.721.41059 | 5848 | Verified locally | 2026-07-29 | Current local runtime baseline. |

An upstream build is a candidate until a maintainer has rebuilt it and verified
it on Linux Mint. Automated checks may open a verification issue, but only a
human verification may mark the build supported.

`tests/linux-automation-smoke.mjs` and
`tests/computer-use-acceptance.mjs` are post-build acceptance tests. They run
against the generated `runtime/codex-app` directory and must be executed only
after a maintainer has performed a local build; generated runtimes are never
committed to this repository.
