#!/usr/bin/env bash
#
# Builds goooeee and packages it as a disk image.
#
#     Tools/build-dmg.sh            # Release build, then build/goooeee-<version>.dmg
#     Tools/build-dmg.sh --debug    # Debug build instead
#     Tools/build-dmg.sh --test     # run the GoooeeeKit package tests first
#     Tools/build-dmg.sh --clean    # start from an empty build folder
#
# Everything goes to build/ in the repository (git-ignored):
#
#     build/goooeee.app             the app
#     build/goooeee-<version>.dmg   the app and an Applications link
#     build/build.log               full xcodebuild output
#     build/test.log                full swift test output (with --test)
#
# The project is regenerated with XcodeGen only when project.yml changed or a Swift file under
# App/ was added or removed. The app is signed as configured in Config/*.xcconfig (ad hoc by
# default), so the disk image opens on this Mac; other Macs need a Developer ID signature.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

configuration=Release
run_tests=false
clean=false
for argument in "$@"; do
    case "$argument" in
        --debug) configuration=Debug ;;
        --test) run_tests=true ;;
        --clean) clean=true ;;
        -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $argument (see --help)" >&2; exit 2 ;;
    esac
done

build="$root/build"
derived="$build/DerivedData"
log="$build/build.log"
project="goooeee.xcodeproj"
resolved="Packages/GoooeeeKit/Package.resolved"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

if $clean; then
    step "Removing $build"
    rm -rf "$build"
fi
mkdir -p "$build"

# MARK: Project

needs_project=false
if [[ ! -f "$project/project.pbxproj" || project.yml -nt "$project/project.pbxproj" ]]; then
    needs_project=true
elif ! diff -q \
    <(find App -name '*.swift' -exec basename {} \; | sort -u) \
    <(grep -oE '/\* [^ ]+\.swift \*/' "$project/project.pbxproj" | sed -E 's|^/\* (.*) \*/$|\1|' | sort -u) \
    >/dev/null; then
    needs_project=true
fi
if $needs_project; then
    command -v xcodegen >/dev/null || fail "Source files changed; install XcodeGen (brew install xcodegen) to regenerate the project."
    step "Regenerating $project"
    xcodegen generate --quiet
fi

# MARK: Tests

if $run_tests; then
    step "Testing GoooeeeKit"
    test_log="$build/test.log"
    if ! (cd Packages/GoooeeeKit && swift test >"$test_log" 2>&1); then
        grep -E '✘' "$test_log" | head -n 20 >&2 || true
        fail "Package tests failed. Full log: $test_log"
    fi
    # Each test target prints its own "Test run with N tests in M suites" line.
    grep -E 'Test run with [0-9]+ tests? in [0-9]+ suites?' "$test_log" \
        | sed -E 's/.*with ([0-9]+) tests? in ([0-9]+) suites?.*/\1 \2/' \
        | awk '{ tests += $1; suites += $2 } END { printf "%d tests in %d suites passed.\n", tests, suites }'
fi

# MARK: Build

# Xcode writes the app's own dependencies into the package's lockfile; put it back afterwards
# if it was unchanged before the build.
resolved_was_clean=false
if git diff --quiet -- "$resolved" 2>/dev/null; then resolved_was_clean=true; fi

step "Building goooeee ($configuration)"
started=$SECONDS
# SwiftTerm's build plugin only records its git version; skipping validation trusts it, as
# Xcode's "Trust & Enable" does.
if ! xcodebuild \
    -project "$project" \
    -scheme goooeee \
    -configuration "$configuration" \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived" \
    -skipPackagePluginValidation \
    build >"$log" 2>&1; then
    $resolved_was_clean && git checkout -- "$resolved" 2>/dev/null || true
    grep -E '^/.*: error:' "$log" | sed "s|$root/||" | sort -u | head -n 40 >&2 || true
    tail -n 5 "$log" >&2
    fail "Build failed. Full log: $log"
fi
$resolved_was_clean && git checkout -- "$resolved" 2>/dev/null || true
echo "Built in $((SECONDS - started))s."

warnings=$(grep -E '^/.*: warning:' "$log" | grep -v '/SourcePackages/' | sed "s|$root/||" | sort -u || true)
if [[ -n "$warnings" ]]; then
    echo "Warnings:"
    echo "$warnings" | head -n 20
fi

built_app="$derived/Build/Products/$configuration/goooeee.app"
[[ -d "$built_app" ]] || fail "The build succeeded but $built_app is missing."

app="$build/goooeee.app"
rm -rf "$app"
ditto "$built_app" "$app"
codesign --verify --deep --strict "$app" || fail "Code signature check failed for $app."

# MARK: Disk image

info="$app/Contents/Info.plist"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")
number=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info")
suffix=""
[[ "$configuration" == Debug ]] && suffix="-debug"
dmg="$build/goooeee-$version$suffix.dmg"

step "Creating $(basename "$dmg")"
staging=$(mktemp -d "${TMPDIR:-/tmp}/goooeee-dmg.XXXXXX")
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/goooeee.app"
ln -s /Applications "$staging/Applications"
rm -f "$dmg"
hdiutil create -quiet -volname "goooeee $version" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg"
hdiutil verify -quiet "$dmg" || fail "hdiutil couldn't verify $dmg."

# MARK: Summary

step "Done"
echo "App:      $app"
echo "Disk:     $dmg ($(du -h "$dmg" | cut -f1 | tr -d ' '))"
echo "Version:  $version ($number), $configuration, commit $(git rev-parse --short HEAD 2>/dev/null || echo unknown)$(git diff --quiet 2>/dev/null || echo ' + local changes')"
# Crash reports name the binary by UUID (slice_uuid); this tells you which build crashed.
dwarfdump --uuid "$app/Contents/MacOS/goooeee" | awk '{ printf "UUID:     %s %s\n", $2, $3 }'
