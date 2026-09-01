# refresh-cache-action — update a GitHub Actions cache under the same cache key

`actions/cache` **will not update a cache entry on a cache hit**. Once something is stored under a
GitHub Actions cache key, that key is immutable: the save step is silently skipped, and your cache
goes stale until you change the key. If you have ever written a rolling cache key with `${{
github.run_id }}` in it and a pile of `restore-keys:` fallbacks just to get a cache that refreshes,
this action is for you.

This is a **composite action** — plain `action.yml` plus one POSIX shell script. No JavaScript, no
`node_modules`, no `dist/` to commit, no runtime dependencies beyond `curl`, which every GitHub
runner already has. It is about 150 lines and you can read all of it in one sitting.

## The problem, in the words people actually search

- **[actions/cache#342 — "It does not update the cache on cache-hit"](https://github.com/actions/cache/issues/342)** — open since 2 June 2020, 200+ 👍.
- **[actions/toolkit#505 — cache: allow overwriting an existing cache entry](https://github.com/actions/toolkit/issues/505)** — 185 👍.
- **[Stack Overflow: "Clear cache in GitHub Actions"](https://stackoverflow.com/questions/63521430/clear-cache-in-github-actions)** — 159 votes, 139k views.

The usual workaround is to delete the cache entry yourself before saving. GitHub used to ship
`actions/gh-actions-cache` for that; **it is archived**. So people copy the same `gh api -X DELETE`
snippet into workflow after workflow. This action is that snippet, packaged, with the error cases
handled.

## Usage

```yaml
jobs:
  build:
    runs-on: ubuntu-latest

    # Required: deleting a cache entry needs `actions: write`.
    permissions:
      contents: read
      actions: write

    steps:
      - uses: actions/checkout@v4

      # 1. Restore with the plain upstream action. No wrapper needed.
      - uses: actions/cache/restore@v4
        with:
          path: ~/.cache/my-tool
          key: my-tool-${{ runner.os }}

      # 2. Do your work. The cache may be a hit or a miss; either is fine.
      - run: ./build.sh

      # 3. Refresh: delete the existing entry under this key, then save a new one.
      - uses: astroanand-6e/refresh-cache-action@v1
        with:
          path: ~/.cache/my-tool
          key: my-tool-${{ runner.os }}
```

`path` and `key` must match what you restored with. That's the whole API.

## Why one action and not a wrapper

A composite action cannot wrap the caller's steps, and — unlike a JavaScript action — it cannot
declare a `post:` step either. So the "one action that restores at the start and saves at the end"
shape is *not implementable* as a composite action. Anything claiming otherwise either ships a
JS bundle or does not actually run.

That leaves two honest shapes: two sub-actions (`restore` / `save`), or one action for the half
that is actually missing. We ship one action, because `actions/cache/restore@v4` already does
restore perfectly and a passthrough wrapper around it would add indirection and a version to keep
in sync for zero benefit. The only thing upstream is missing is **save-over-an-existing-key**, so
that is the only thing here.

## `actions: write` is required — this is the #1 gotcha

Deleting a cache entry calls `DELETE /repos/{owner}/{repo}/actions/caches?key=...`, which needs the
`actions: write` permission. If your workflow sets any `permissions:` block, or your repository /
organization defaults `GITHUB_TOKEN` to read-only, you will get a **403** and your cache will
silently stay stale.

```yaml
permissions:
  contents: read
  actions: write
```

The action names this fix explicitly in the 403 error message rather than making you decode a bare
HTTP status.

**Fork pull requests:** `GITHUB_TOKEN` is always read-only for workflows triggered by a PR from a
fork, and no `permissions:` block can change that. Either skip the refresh there:

```yaml
- uses: astroanand-6e/refresh-cache-action@v1
  if: github.event.pull_request.head.repo.fork != true
  with:
    path: ~/.cache/my-tool
    key: my-tool-${{ runner.os }}
```

…or pass a PAT with the `repo` scope via `token:`.

## Behaviour in the awkward cases

| Situation | What happens |
| --- | --- |
| Cache miss — nothing stored under the key | Delete returns 404. Logged as a notice, **build does not fail**, save proceeds. |
| Entry exists on a different ref | Delete returns 404 (cache entries are scoped per ref). Save proceeds and creates the entry for this ref. |
| Missing `actions: write` | 403. Warning naming the exact fix; save still attempted. Set `fail-on-delete-error: true` to make it fatal. |
| Token invalid / expired | 401, same handling as above. |
| API unreachable | Warning, save still attempted. |

The default is deliberately non-fatal: a caching optimisation should not break your build. Flip
`fail-on-delete-error: true` if you would rather know loudly.

## Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `path` | yes | — | Files, directories and wildcard patterns to cache. Same syntax as `actions/cache`. |
| `key` | yes | — | The cache key to refresh. The existing entry under this key is deleted, then re-saved. |
| `ref` | no | `${{ github.ref }}` | Git ref the entry is scoped to. Cache entries are per-ref. |
| `token` | no | `${{ github.token }}` | Token used for the delete call. Needs `actions: write`. |
| `upload-chunk-size` | no | — | Passed through to `actions/cache/save`. |
| `enableCrossOsArchive` | no | `false` | Passed through to `actions/cache/save`. |
| `fail-on-delete-error` | no | `false` | Fail the step if the delete fails. |
| `skip-delete` | no | `false` | Skip the delete and only save. For debugging. |

## Outputs

| Name | Description |
| --- | --- |
| `deleted` | `"true"` if an existing entry was deleted, `"false"` otherwise. |
| `http-status` | HTTP status from the delete call, or `"skipped"`. |

## Self-test workflow

This is the workflow used to verify the action against the real cache API. Run 1 stores a
timestamp; every later run must read back the timestamp written by the run before it. If
`actions/cache` semantics applied, the value would never change after run 1.

```yaml
name: self-test

on:
  push:
  workflow_dispatch:

jobs:
  refresh:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      actions: write
    steps:
      - uses: actions/checkout@v4

      - id: restore
        uses: actions/cache/restore@v4
        with:
          path: .cache-probe
          key: refresh-cache-selftest-${{ github.ref_name }}

      - name: Show what we restored
        run: |
          if [ -f .cache-probe/stamp ]; then
            echo "restored stamp: $(cat .cache-probe/stamp)"
          else
            echo "cache miss (expected on the first run)"
          fi

      - name: Write a new stamp
        run: |
          mkdir -p .cache-probe
          date -u +%Y-%m-%dT%H:%M:%SZ > .cache-probe/stamp
          echo "new stamp: $(cat .cache-probe/stamp)"

      - id: refresh
        uses: ./
        with:
          path: .cache-probe
          key: refresh-cache-selftest-${{ github.ref_name }}

      - run: |
          echo "deleted=${{ steps.refresh.outputs.deleted }}"
          echo "http-status=${{ steps.refresh.outputs.http-status }}"
```

## License

MIT. See [LICENSE](LICENSE).
