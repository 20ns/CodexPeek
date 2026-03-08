# Release Notes

## Packaging

Build local release artifacts:

```bash
./Scripts/build_release.sh
./Scripts/build_dmg.sh
```

Outputs:
- `dist/CodexPeek.zip`
- `dist/CodexPeek.dmg`

## Public Release Checklist

- Run `swift run CodexPeek --self-test`
- Build `.zip` and `.dmg`
- Confirm the `/Applications` install launches correctly
- Verify launch-at-login from the installed copy
- Update README screenshots if needed
- Tag and publish a GitHub release

## Signing / Notarization

This repo currently builds unsigned local artifacts. For a smoother public macOS install flow, the next step is Apple code signing and notarization.
