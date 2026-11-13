# Local patches on top of upstream Haven

The `Dockerfile` applies every `*.patch` here, in name order, to the cloned
upstream tree before building. A patch that no longer applies fails the build
on purpose: drop it once upstream carries the fix.

| Patch | Why | Drop when |
|---|---|---|
| `0001-blossom-accept-bud11-base64url-auth.patch` | khatru v0.19.1 rejects BUD-11 (base64url) Blossom auth tokens — #13, barrydeen/haven#138 | Haven ships a khatru that decodes base64url tokens |
| `eventstore/0001-lmdb-advance-cursor-when-counting.patch` | eventstore v0.17.5 never advances the LMDB cursor after counting a match: one NIP-45 `COUNT` that matches an event never answers and pegs a core until the relay restarts; a count that needs an extra author/kind/tag check answers 0 — fiatjaf/eventstore#78, barrydeen/haven#139 | Haven requires an eventstore that contains fiatjaf/eventstore#78 (first tag: v0.17.15), or merges barrydeen/haven#139. The build then stops at the eventstore step: remove that step from the `Dockerfile` together with `eventstore/` |
| `0002-lmdb-count-regression-test.patch` | The test for the row above, run in the image build: LMDB counts return the exact number within 10 s, for `CountEvents` and `CountEventsHLL` | With the row above, together with its two `go test` lines in the `Dockerfile`. It passes on any eventstore that has the fix, so it may stay one release longer to let the build prove upstream's |

## Patches to a dependency

`eventstore/` holds patches to the Go module `github.com/fiatjaf/eventstore`,
not to Haven. The `Dockerfile` copies that module out of the module cache at
the version Haven's `go.mod` pins, applies the patches to the copy in
`third_party/eventstore`, and adds a `replace` for it. Nothing else about the
dependency graph changes. The step fails the build when

- Haven requires any version other than the one the patch is cut for (v0.17.5),
- Haven's `go.mod` already replaces the module, or `third_party/eventstore` exists,
- a patch does not apply, or `eventstore/` holds no patch.

The patch file is `git format-patch` of upstream commit `292b3b6`, unchanged.
After it, every `.go` file in the module's `lmdb/` package is byte-identical to
upstream at the merge of fiatjaf/eventstore#78 (`d75df7d`); the storage code
and the on-disk format are those of v0.17.5.

`go version -m /app/haven-bin` shows the replacement in the built image:

```
dep	github.com/fiatjaf/eventstore	v0.17.5
=>	./third_party/eventstore	(devel)
```
