#!/bin/sh

# Xcode Cloud post-clone script
# Combines the manual CURRENT_PROJECT_VERSION from project.yml with
# CI_BUILD_NUMBER to produce a unique, always-incrementing build version.
# Example: project.yml has "60", CI build #3 → version "60.3"

if [ -n "$CI_BUILD_NUMBER" ]; then
    # Extract the base version from project.yml
    BASE_VERSION=$(grep 'CURRENT_PROJECT_VERSION' "$CI_PRIMARY_REPOSITORY_PATH/project.yml" | head -1 | sed 's/.*"\([0-9]*\)".*/\1/')
    COMBINED="${BASE_VERSION}.${CI_BUILD_NUMBER}"

    echo "Setting CURRENT_PROJECT_VERSION to $COMBINED (base=$BASE_VERSION, ci=$CI_BUILD_NUMBER)"

    # Update project.yml so xcodegen picks it up
    sed -i '' "s/CURRENT_PROJECT_VERSION: \"[0-9]*\"/CURRENT_PROJECT_VERSION: \"$COMBINED\"/" "$CI_PRIMARY_REPOSITORY_PATH/project.yml"

    # Regenerate the Xcode project if xcodegen is available
    if command -v xcodegen >/dev/null 2>&1; then
        echo "Regenerating Xcode project with xcodegen..."
        cd "$CI_PRIMARY_REPOSITORY_PATH" && xcodegen generate
    else
        # If no xcodegen, update the pbxproj directly
        echo "Updating pbxproj directly..."
        sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*/CURRENT_PROJECT_VERSION = $COMBINED/g" "$CI_PRIMARY_REPOSITORY_PATH/AdagioStream.xcodeproj/project.pbxproj"
    fi
fi
