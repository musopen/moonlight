#!/bin/sh
# Bundles the optional local Firebase configuration without adding it to the project.
# Remove an earlier bundled copy when the local configuration is absent.
set -eu

source_plist="${SRCROOT}/Sources/App/GoogleService-Info.plist"
bundled_plist="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/GoogleService-Info.plist"

if [ -f "$source_plist" ]; then
    /usr/bin/plutil -lint "$source_plist" >/dev/null
    /bin/mkdir -p "$(/usr/bin/dirname "$bundled_plist")"
    /usr/bin/install -m 644 "$source_plist" "$bundled_plist"
else
    /bin/rm -f "$bundled_plist"
fi
