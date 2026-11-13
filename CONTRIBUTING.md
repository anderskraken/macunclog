# Contributing

Thanks for helping. A few things keep MacUnclog safe to run on other people's Macs.

## Before you open a pull request

- Run the tests: `xcodebuild -project MacUnclog.xcodeproj -scheme MacUnclog -derivedDataPath build/dd test`. CI fails on any compiler warning.
- If you add or remove files, run `xcodegen generate` and commit the updated `MacUnclog.xcodeproj`.
- If you change user-facing text, run `scripts/sync-strings.sh` and add the Norwegian translation in `MacUnclog/Resources/Localizable.xcstrings` (Xcode's string catalog editor works well). CI fails on missing translations.
- To update the screenshots, run `scripts/screenshots.sh dark` and `scripts/screenshots.sh light`. They use demo data, so they never show your own projects.

## Anything that deletes or stops

- Every deletion must go through `SafeDeleter`, which asks `PathGuard`. Don't call `FileManager.removeItem` anywhere else.
- A new cleanup category needs a scanner that fails closed: if a tool it relies on fails or times out, offer nothing or mark items as blocked.
- Add a test that shows the new rule blocks what it should. The tests in `MacUnclogTests/ProjectBuildTests.swift` build real projects in `~/Library/Caches` and are a good template.
- Update the table in `README.md` and `CleanupCategory.whatIsDeleted` together.
