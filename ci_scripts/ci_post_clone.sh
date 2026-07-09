#!/bin/sh

# Xcode Cloud post-clone script
#
# Build number (CURRENT_PROJECT_VERSION) is controlled entirely by
# Xcode Cloud's CI_BUILD_NUMBER. To change it, set "Next Build Number"
# in App Store Connect → Xcode Cloud → Settings → Build Number.
#
# Steps (CI only, guarded on $CI_PRIMARY_REPOSITORY_PATH):
#   1. Regenerate the Xcode project with xcodegen.
#   2. Pre-resolve SPM packages with a retry/backoff loop.
#
# Why (2): VLCKitSPM is a *binary* SPM target whose large xcframework zip
# (VLCKit-all.xcframework.zip, hundreds of MB) is downloaded from GitHub
# releases during package resolution. That download times out in Xcode Cloud
# a lot, and the build's own resolution is one-shot — a single timeout fails
# the whole build. Resolving here first, with retries, lets a transient
# timeout recover before the build ever runs. -resolvePackageDependencies
# populates SPM's real checksum-keyed artifact cache, so the build's later
# resolution is a cache hit. (A hand-placed curl download would NOT satisfy
# that cache, so retries on the real command are the core mechanism.)
#
# ESCALATION — if retries still aren't enough (persistent GitHub-release
# flakiness), the durable fixes are:
#   (a) Mirror VLCKit-all.xcframework.zip on a reliable host and point the
#       binary target's URL there (fork tylerjonesio/vlckit-spm, edit its
#       Package.swift binaryTarget url + checksum, pin to the fork).
#   (b) Vendor the xcframework into this repo via Git LFS and switch
#       VLCKitSPM from a remote binary target to a local binaryTarget(path:).
# Both are heavier; do them only if this retry loop proves insufficient.

if [ -n "$CI_PRIMARY_REPOSITORY_PATH" ]; then
    cd "$CI_PRIMARY_REPOSITORY_PATH"

    if command -v xcodegen >/dev/null 2>&1; then
        echo "Regenerating Xcode project with xcodegen..."
        xcodegen generate
    fi

    # Pre-resolve SPM packages with retry/backoff so the large VLCKit binary
    # download survives a transient timeout. Backoff: 15s, 30s, 60s, 120s.
    if command -v xcodebuild >/dev/null 2>&1 && [ -d "AdagioStream.xcodeproj" ]; then
        # Keep resolved packages under the CI derived-data dir so the build
        # reuses the exact same cache.
        SPM_DIR="${CI_DERIVED_DATA_PATH:-$CI_PRIMARY_REPOSITORY_PATH/DerivedData}/SourcePackages"

        attempt=1
        max_attempts=5
        sleep_s=15
        resolved=0
        while [ "$attempt" -le "$max_attempts" ]; do
            echo "Resolving SPM packages (attempt $attempt/$max_attempts)..."
            if xcodebuild -resolvePackageDependencies \
                -project AdagioStream.xcodeproj \
                -scheme AdagioStream \
                -clonedSourcePackagesDirPath "$SPM_DIR"; then
                echo "SPM packages resolved."
                resolved=1
                break
            fi
            echo "Resolution failed (attempt $attempt). Retrying in ${sleep_s}s..."
            sleep "$sleep_s"
            attempt=$((attempt + 1))
            sleep_s=$((sleep_s * 2))
        done

        if [ "$resolved" -ne 1 ]; then
            echo "ERROR: SPM package resolution failed after $max_attempts attempts." >&2
            echo "The VLCKit binary download likely timed out repeatedly." >&2
            echo "See escalation options in this script's header comment." >&2
            exit 1
        fi
    fi
fi
