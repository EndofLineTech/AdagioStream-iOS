#!/bin/sh

# Xcode Cloud post-clone script
#
# Build number (CURRENT_PROJECT_VERSION) is controlled entirely by
# Xcode Cloud's CI_BUILD_NUMBER. To change it, set "Next Build Number"
# in App Store Connect → Xcode Cloud → Settings → Build Number.
#
# Regenerate the Xcode project with xcodegen if available.

if [ -n "$CI_PRIMARY_REPOSITORY_PATH" ]; then
    cd "$CI_PRIMARY_REPOSITORY_PATH"

    if command -v xcodegen >/dev/null 2>&1; then
        echo "Regenerating Xcode project with xcodegen..."
        xcodegen generate
    fi
fi
