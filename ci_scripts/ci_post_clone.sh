#!/bin/sh

# Xcode Cloud post-clone script
# Generates a monotonically increasing build number using epoch minutes.
# This guarantees the version is always higher than any previous upload,
# regardless of CI_BUILD_NUMBER resets or manual version bumps.
# Example: 2026-03-15 at 18:30 UTC → 29584350

if [ -n "$CI_BUILD_NUMBER" ]; then
    # Minutes since Unix epoch — always increases, fits in CFBundleVersion
    BUILD_VERSION=$(( $(date +%s) / 60 ))

    echo "Setting CURRENT_PROJECT_VERSION to $BUILD_VERSION (CI_BUILD_NUMBER=$CI_BUILD_NUMBER)"

    # Update project.yml so xcodegen picks it up
    sed -i '' "s/CURRENT_PROJECT_VERSION: \"[^\"]*\"/CURRENT_PROJECT_VERSION: \"$BUILD_VERSION\"/" "$CI_PRIMARY_REPOSITORY_PATH/project.yml"

    # Regenerate the Xcode project if xcodegen is available
    if command -v xcodegen >/dev/null 2>&1; then
        echo "Regenerating Xcode project with xcodegen..."
        cd "$CI_PRIMARY_REPOSITORY_PATH" && xcodegen generate
    else
        # If no xcodegen, update the pbxproj directly
        echo "Updating pbxproj directly..."
        sed -i '' "s/CURRENT_PROJECT_VERSION = [^;]*/CURRENT_PROJECT_VERSION = $BUILD_VERSION/g" "$CI_PRIMARY_REPOSITORY_PATH/AdagioStream.xcodeproj/project.pbxproj"
    fi
fi
