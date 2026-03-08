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

## Unsigned Public Release

Current releases are unsigned and not notarized.

That means users may see the standard macOS "unidentified developer" warning on first launch. Public release notes and the README should tell users to:

1. Move `CodexPeek.app` into `/Applications`
2. Right-click `CodexPeek.app`
3. Choose `Open`
4. Confirm `Open`

If needed, they can also allow the app in `System Settings > Privacy & Security`.

## Public Release Checklist

- Run `swift run CodexPeek --self-test`
- Build `.zip` and `.dmg`
- Confirm the `/Applications` install launches correctly
- Verify launch-at-login from the installed copy
- Confirm the unsigned first-launch instructions in the README are accurate
- Update README screenshots if needed
- Tag and publish a GitHub release

## Signing / Notarization

This repo currently builds unsigned local artifacts. For a smoother public macOS install flow later, the next step is Apple code signing and notarization.
