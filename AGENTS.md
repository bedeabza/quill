# Repository instructions

## Branching

- Work lands on `master`. Push to `origin/master` by default.

## macOS builds and signing

- Read `AGENTS.local.md` when present for machine-specific build and delivery requirements. Keep that file out of version control.
- Reuse your own code-signing certificate across app updates so macOS permission grants remain associated with the same designated requirement.
- Build with `swift build -c release`, then package with `python3 tools/package-app.py --signing-identity "<your signing identity>"`.
- Use an explicit signing identity for delivered apps so an unavailable certificate fails instead of silently falling back to ad hoc signing.
- Verify the packaged app with `codesign --verify --strict .build/Quill.app` and inspect `codesign -d -r- --verbose=2 .build/Quill.app` for the selected authority and a certificate-based designated requirement.
- Deliver `.build/Quill.app`; a ZIP is optional. Do not replace or restart an installed app unless requested.
