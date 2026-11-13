#!/bin/bash
# Adds new strings from the code to the string catalogs, marks removed ones
# stale, then checks that every string has a Norwegian translation.
#
#   scripts/sync-strings.sh              build into build/l10n, then sync and check
#   scripts/sync-strings.sh --no-build   reuse an existing build (CI sets DERIVED_DATA=build/dd)
#
# project.yml sets SWIFT_EMIT_LOC_STRINGS=YES, which makes Swift write the .stringsdata files.
set -euo pipefail
cd "$(dirname "$0")/.."

derived=${DERIVED_DATA:-build/l10n}
catalogs=(MacUnclog/Resources/Localizable.xcstrings MacUnclog/Resources/AppShortcuts.xcstrings)

if [[ ${1:-} != --no-build ]]; then
  xcodebuild -project MacUnclog.xcodeproj -scheme MacUnclog -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$derived" \
    -quiet build
fi

# The app target only. The test target's strings never reach users.
stringsdata=()
while IFS= read -r -d '' file; do stringsdata+=("$file"); done < <(
  find "$derived/Build/Intermediates.noindex" -path '*/MacUnclog.build/Objects-normal/*' \
    -name '*.stringsdata' -print0)
if (( ${#stringsdata[@]} == 0 )); then
  echo "No app .stringsdata under $derived. Build with SWIFT_EMIT_LOC_STRINGS=YES." >&2
  exit 1
fi

xcrun xcstringstool sync "${catalogs[@]}" --stringsdata "${stringsdata[@]}"
python3 -I scripts/check-translations.py "${catalogs[@]}"
