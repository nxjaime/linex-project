# Compatibility

| Upstream app version | Internal build | Linux Mint status | Verified on | Notes |
| --- | ---: | --- | --- | --- |
| 26.727.51351 | 6119 | Verified locally | 2026-08-01 | Human-approved remote handoff; stable runtime promoted with automatic rollback health check. |
| 26.721.41059 | 5848 | Verified locally | 2026-07-29 | Current local runtime baseline. |

An upstream build is a candidate until a maintainer has rebuilt it and verified
it on Linux Mint. Automated checks may open a verification issue, but only a
human verification may mark the build supported. After approval, promotion is
a queued handoff: the active app closes first, then the local runner switches
and launches the candidate. Record a compatibility result only after the
replacement has opened and the maintainer has reconnected to verify it.

After human verification and promotion, add the approved build's version,
internal build, status, and verification date to the table above, then record
it in the private source-only repository:

```bash
# Replace fields with the approved app metadata and date.
git add docs/compatibility.md
git commit -m "docs: verify Mint app <upstream-version>"
git tag -a "mint-app-<upstream-version>" -m "Verified on Linux Mint: build <build>"
git push origin main --follow-tags
```

Create the annotated `mint-app-<upstream-version>` tag only after human
verification. The GitHub verification issue may be closed only after this
compatibility commit and tag have been pushed.

`tests/linux-automation-smoke.mjs` and
`tests/computer-use-acceptance.mjs` are post-build acceptance tests. They run
against the generated `runtime/codex-app` directory and must be executed only
after a maintainer has performed a local build; generated runtimes are never
committed to this repository.
