#!/bin/sh

# Xcode Cloud post-clone script
# Uses CI_BUILD_NUMBER directly as CURRENT_PROJECT_VERSION.
# CI_BUILD_NUMBER always increments within Xcode Cloud, ensuring
# each upload to App Store Connect has a unique, higher build number.

if [ -n "$CI_BUILD_NUMBER" ]; then
    echo "Setting CURRENT_PROJECT_VERSION to $CI_BUILD_NUMBER"

    # Update project.yml so xcodegen picks it up
    sed -i '' "s/CURRENT_PROJECT_VERSION: \"[^\"]*\"/CURRENT_PROJECT_VERSION: \"$CI_BUILD_NUMBER\"/" "$CI_PRIMARY_REPOSITORY_PATH/project.yml"

    # Regenerate the Xcode project if xcodegen is available
    if command -v xcodegen >/dev/null 2>&1; then
        echo "Regenerating Xcode project with xcodegen..."
        cd "$CI_PRIMARY_REPOSITORY_PATH" && xcodegen generate
    else
        # If no xcodegen, update the pbxproj directly
        echo "Updating pbxproj directly..."
        sed -i '' "s/CURRENT_PROJECT_VERSION = [^;]*/CURRENT_PROJECT_VERSION = $CI_BUILD_NUMBER/g" "$CI_PRIMARY_REPOSITORY_PATH/AdagioStream.xcodeproj/project.pbxproj"
    fi
fi
