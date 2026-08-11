# Compatibility

| Upstream app version | Internal build | Linux Mint status | Verified on | Notes | Upstream identity |
| --- | ---: | --- | --- | --- | --- |
| 26.803.81509 | 6415 | Owner-approved protected handoff | 2026-08-10 | Automated browser bridge, Linux smoke, Computer Use, and browser-surface gates passed; Debian package built; replacement relaunched and remained healthy through the 45-second window. Live in-app Browser and external Chrome verification remain post-launch follow-ups; Firefox was verified through X11 Computer Use. | d5bc4866c41d6fa95c64ae72ec97a0c12f0f1146b549526d1b8cb49d483b0303 |
| 26.803.61601 | 6396 | Owner-approved protected handoff | 2026-08-10 | Automated browser bridge, Linux smoke, Computer Use, and browser-surface gates passed; replacement relaunched and remained healthy through the 45-second window. In-app Browser live verification remains a post-launch follow-up; external Chrome was not available because its extension was not connected. Firefox was exercised through X11 Computer Use; typing worked for letters but punctuation was dropped in the manual check. | 008b34038214149d0cf72fe41855006f55c1612331319ac590ed2cfef2e448ff |
| 26.730.61639 | 6234 | Verified locally | 2026-08-05 | Owner-approved protected handoff; automated Linux smoke test passed and the replacement remained healthy through the 45-second rollback window. Browser-surface compatibility was not part of this earlier record. | not-recorded |
| 26.727.51351 | 6119 | Verified locally | 2026-08-01 | Human-approved remote handoff; stable runtime promoted with automatic rollback health check. | not-recorded |
| 26.721.41059 | 5848 | Verified locally | 2026-07-29 | Current local runtime baseline. | not-recorded |

An upstream build is a candidate until a maintainer has rebuilt it and verified
it on Linux Mint. Automated checks may open a verification issue, but only a
human verification may mark the build supported. After approval, promotion is
a queued handoff: the active app closes first, then the local runner switches
and launches the candidate. Record a compatibility result only after the
replacement has opened and the maintainer has reconnected to verify it.

The scheduled workflow records the selected appcast version, build, archive
URL, HTTP identity headers, and a deterministic upstream fingerprint in each
verification issue. The fingerprint is used only to deduplicate and supersede
drift reports; it never installs or promotes a candidate. Locally generated
candidates record the same schema in `source-fingerprint.json` beside
`app-version` and `app-build`.

Each compatibility record must include the tested browser surfaces: in-app
Browser, external Chrome extension (verified or explicitly not available), and
Firefox through X11 Computer Use. The automated candidate gate runs these
commands against the candidate runtime before approval:

```bash
CODEX_APP_RUNTIME_DIR=/path/to/candidate node tests/node-repl-browser-compat.test.mjs
CODEX_APP_RUNTIME_DIR=/path/to/candidate node tests/linux-automation-smoke.mjs
CODEX_APP_RUNTIME_DIR=/path/to/candidate node tests/computer-use-acceptance.mjs
CODEX_APP_RUNTIME_DIR=/path/to/candidate node tests/browser-surface-acceptance.mjs
```

The browser surface report is an asset and trust-boundary check during a
headless candidate build. Live in-app Browser and external Chrome behavior are
verified after the candidate is launched, under the human approval gate. A
missing Chrome extension is an environmental exception, not a compatibility
pass.

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
