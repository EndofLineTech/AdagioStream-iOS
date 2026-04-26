#!/bin/sh

# Xcode Cloud post-clone script
#
# Build number (CURRENT_PROJECT_VERSION) is controlled entirely by
# Xcode Cloud's CI_BUILD_NUMBER. To change it, set "Next Build Number"
# in App Store Connect → Xcode Cloud → Settings → Build Number.
#
# AdagioStreamCore (sibling repo) — checked out next to AdagioStream-iOS so
# the local-path SwiftPM reference at `../AdagioStreamCore` resolves. CI
# may need explicit clone steps for the sibling repo if it isn't auto-
# included; consult Xcode Cloud workflow settings for "additional
# repositories" or use a sibling-clone block here when the path is
# missing at run time.

if [ -n "$CI_PRIMARY_REPOSITORY_PATH" ]; then
    cd "$CI_PRIMARY_REPOSITORY_PATH"

    # Ensure the sibling AdagioStreamCore checkout exists. Xcode Cloud's
    # default behavior clones only the primary repo, so we may need to
    # clone the Core sibling explicitly. Adjust the URL when remotes
    # are configured.
    if [ ! -d "../AdagioStreamCore" ]; then
        echo "WARNING: ../AdagioStreamCore not found. Local-path SwiftPM" \
             "dependency 'AdagioStreamCore' will fail to resolve."
        echo "Configure Xcode Cloud to also clone the sibling Core" \
             "repository, OR add an explicit \`git clone\` here once" \
             "the Core remote is set up."
    fi

    if command -v xcodegen >/dev/null 2>&1; then
        echo "Regenerating Xcode project with xcodegen..."
        xcodegen generate
    fi
fi
