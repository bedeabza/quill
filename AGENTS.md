# Repository instructions

## Branching

- Work lands on `master`. Push to `origin/master` by default.

## macOS builds and signing

- Always sign replacement Quill apps with the existing **Quill Local Signing** identity in the login Keychain. This is the user's required signing identity for this project.
- Build and package with:

  ```sh
  swift build -c release
  python3 tools/package-app.py --signing-identity "Quill Local Signing"
  ```

- Use the explicit signing identity so a missing certificate fails instead of silently falling back to ad hoc signing. Never use `--signing-identity -` for a delivered app unless the user explicitly requests it.
- The local identity was created on November 9, 2026. Reuse it across builds; do not delete, replace or regenerate it routinely. If unavailable, diagnose Keychain access and recover the existing identity before creating a replacement.
- Before delivery, verify `codesign --verify --strict .build/Quill.app` succeeds and `codesign -d -r- --verbose=2 .build/Quill.app` shows `Authority=Quill Local Signing` and a certificate-based designated requirement. Preserve the same certificate across updates.
- Deliver `.build/Quill.app` for the user to copy over the installed app; a ZIP is optional. Do not replace or restart the installed app unless requested.
