# Local patches on top of upstream Haven

The `Dockerfile` applies every `*.patch` here, in name order, to the cloned
upstream tree before building. A patch that no longer applies fails the build
on purpose: drop it once upstream carries the fix.

| Patch | Why | Drop when |
|---|---|---|
| `0001-blossom-accept-bud11-base64url-auth.patch` | khatru v0.19.1 rejects BUD-11 (base64url) Blossom auth tokens — #13, barrydeen/haven#138 | Haven ships a khatru that decodes base64url tokens |
