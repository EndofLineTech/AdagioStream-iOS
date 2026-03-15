#!/bin/sh

# Xcode Cloud post-xcodebuild script
# Stamps the archive's Info.plist with an epoch-minutes build number
# AFTER the build completes but BEFORE App Store Connect upload.
# This overrides whatever CI_BUILD_NUMBER Xcode Cloud applied.

if [ -n "$CI_ARCHIVE_PATH" ]; then
    BUILD_VERSION=$(( $(date +%s) / 60 ))
    PLIST="$CI_ARCHIVE_PATH/Info.plist"

    echo "Stamping archive build version to $BUILD_VERSION"

    # Update the archive's Info.plist
    /usr/libexec/PlistBuddy -c "Set :ApplicationProperties:CFBundleVersion $BUILD_VERSION" "$PLIST" 2>/dev/null

    # Also update the app's Info.plist inside the archive
    APP_PLIST=$(find "$CI_ARCHIVE_PATH/Products" -name "Info.plist" -path "*.app/*" | head -1)
    if [ -n "$APP_PLIST" ]; then
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_VERSION" "$APP_PLIST"
        echo "Updated app Info.plist: $APP_PLIST"
    fi
fi
