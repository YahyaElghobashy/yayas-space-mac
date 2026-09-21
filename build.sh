#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint

# Builds Yaya's Space, assembles the .app bundle, signs it and (with --install)
# installs it into /Applications.
#
# The bundle is staged in a temporary directory outside ~/Documents: folders synced
# by File Provider gain xattrs (com.apple.provenance etc.) that invalidate codesign.
set -euo pipefail
cd "$(dirname "$0")"

# The icon catalog and the bundle are staged in temp dirs; sweep both however
# the script ends.
ICON_TMP=""
STAGE_TMP=""

cleanup() {
    [[ -n "$ICON_TMP" ]] && rm -rf "$ICON_TMP"
    [[ -n "$STAGE_TMP" ]] && rm -rf "$STAGE_TMP"
    return 0
}
trap cleanup EXIT
# zsh runs the EXIT trap when the script is hung up, but not when it is
# interrupted or terminated; route those through exit so a Ctrl-C partway
# into the build sweeps like any other ending.
trap 'exit 1' INT TERM HUP

# Flags: --dev builds the local-only "Yaya's Space (Developer)" variant (its own
# bundle id, so it coexists with the official app); --install puts it in /Applications.
DEV=0
INSTALL=0
TEST=0
for arg in "$@"; do
    case "$arg" in
        --dev)     DEV=1 ;;
        --install) INSTALL=1 ;;
        --test)    TEST=1 ;;
    esac
done

if (( DEV )); then
    APP_NAME="Yaya's Space (Developer)"
    EXECUTABLE="YayasSpaceDeveloper"
    APP_BUNDLE_ID="com.yahyaelghobashy.yayasspace.dev"
    BUILD_VARIANT_FLAGS=(-D YAYASSPACE_DEVELOPMENT)
    APP_OPTIMIZATION_FLAGS=(-Onone)
    BUILD_CONFIGURATION="debug"
else
    APP_NAME="Yaya's Space"
    EXECUTABLE="YayasSpace"
    APP_BUNDLE_ID="com.yahyaelghobashy.yayasspace"
    BUILD_VARIANT_FLAGS=()
    APP_OPTIMIZATION_FLAGS=(-O)
    BUILD_CONFIGURATION="release"
fi
FAN_HELPER_ID="$APP_BUNDLE_ID.fan-control"
# Now Playing is read through /usr/bin/perl loading this library; see
# Sources/NowPlayingAdapter. Staged under Contents/Frameworks, signed on its own.
NOW_PLAYING_ADAPTER_ID="$APP_BUNDLE_ID.now-playing"
NOW_PLAYING_ADAPTER="libYayasSpaceNowPlaying.dylib"
TARGET="arm64-apple-macosx14.0"
ENTITLEMENTS="Resources/YayasSpace.entitlements"
LEGACY_IDENTITY="Yaya's Space Signing"

developer_id_identity() {
    security find-identity -v -p codesigning 2>/dev/null \
        | grep 'Developer ID Application' \
        | head -1 \
        | sed -E 's/.*"(.*)".*/\1/' || true
}

# A find-identity listing also names certificates codesign then rejects (an
# expired one fails the build with errSecInternalComponent), and -v excludes
# every self-signed one; ask codesign itself with a throwaway copy of /bin/echo.
legacy_identity_installed() {
    local probe signed=1
    # A locked keychain still lists its identities but cannot sign with them,
    # and this one is locked after every reboot; unlock it before asking.
    security unlock-keychain -p yayasspace-signing \
        "$HOME/Library/Keychains/yayasspace-signing.keychain-db" 2>/dev/null || true
    probe="$(mktemp)"
    cp /bin/echo "$probe"
    /usr/bin/codesign --force --strip-disallowed-xattrs --sign "$LEGACY_IDENTITY" "$probe" \
        >/dev/null 2>&1 && signed=0
    rm -f "$probe"
    return $signed
}

# Any build that lands in /Applications needs a stable signature, not just the
# Developer one: macOS ties Accessibility and Screen Recording grants to the
# exact binary hash, so an ad-hoc rebuild orphans them while System Settings
# keeps showing them as granted, and no new prompt ever appears. A plain
# --install strands them under the released bundle id, on the app the user
# actually relies on. When no identity is installed, create the stable local one
# up front instead of falling through to ad-hoc — setup-signing.sh is free,
# offline and idempotent. Gating on the install rather than the variant keeps
# this off CI, where neither ci.yml nor release.yml passes --install.
# Sealed fork: a plain --dev build (no --install) must not touch the keychain,
# so it falls straight through to ad-hoc signing. --install keeps the upstream
# behaviour, and the release path is untouched.
if (( INSTALL )) && [[ -z "$(developer_id_identity)" ]] \
    && ! legacy_identity_installed; then
    echo "▸ No signing identity installed; creating the stable local one…"
    if ! ./Tools/setup-signing.sh; then
        echo "  ⚠ Tools/setup-signing.sh failed; signing ad-hoc instead." >&2
        echo "    Accessibility and Screen Recording grants will not survive rebuilds:" >&2
        echo "    System Settings will show them as granted while the app is not trusted." >&2
        echo "    After fixing the identity, clear the stale grant once with:" >&2
        echo "      tccutil reset Accessibility $APP_BUNDLE_ID" >&2
    fi
fi

codesign_with_timestamp_retry() {
    local attempt
    for attempt in 1 2 3; do
        if /usr/bin/codesign "$@"; then
            return 0
        fi
        if (( attempt < 3 )); then
            echo "  Developer ID signing failed; retrying ($((attempt + 1))/3)"
            sleep "$attempt"
        fi
    done
    return 1
}

write_swift_output_file_map() {
    local output_file="$1"
    local object_dir="$2"
    shift 2
    local source artifact

    {
        print -r -- "{"
        print -r -- "  \"\": {"
        print -r -- "    \"swift-dependencies\": \"$object_dir/master.swiftdeps\""
        print -r -- "  }"
        for source in "$@"; do
            artifact="${source//\//__}"
            artifact="${artifact%.swift}"
            print -r -- ","
            print -r -- "  \"$source\": {"
            print -r -- "    \"object\": \"$object_dir/$artifact.o\","
            print -r -- "    \"swift-dependencies\": \"$object_dir/$artifact.swiftdeps\""
            print -r -- "  }"
        done
        print -r -- "}"
    } > "$output_file"
}

finalize_installed_bundle_after_child() {
    local bundle="$1"
    local helper="$bundle/Contents/Library/LaunchServices/$FAN_HELPER_ID"
    local adapter="$bundle/Contents/Frameworks/$NOW_PLAYING_ADAPTER"
    local devid
    devid="$(developer_id_identity)"

    echo "▸ Finalizing installed signature…"
    sleep 3
    if [[ -n "$devid" ]]; then
        [[ -f "$helper" ]] && codesign_with_timestamp_retry --force --strip-disallowed-xattrs \
            --options runtime --timestamp --identifier "$FAN_HELPER_ID" --sign "$devid" "$helper"
        [[ -f "$adapter" ]] && codesign_with_timestamp_retry --force --strip-disallowed-xattrs \
            --options runtime --timestamp --identifier "$NOW_PLAYING_ADAPTER_ID" --sign "$devid" "$adapter"
        codesign_with_timestamp_retry --force --strip-disallowed-xattrs --options runtime --timestamp \
            --entitlements "$ENTITLEMENTS" --sign "$devid" "$bundle"
    elif legacy_identity_installed; then
        [[ -f "$helper" ]] && /usr/bin/codesign --force --strip-disallowed-xattrs \
            --identifier "$FAN_HELPER_ID" --sign "$LEGACY_IDENTITY" "$helper"
        [[ -f "$adapter" ]] && /usr/bin/codesign --force --strip-disallowed-xattrs \
            --identifier "$NOW_PLAYING_ADAPTER_ID" --sign "$LEGACY_IDENTITY" "$adapter"
        /usr/bin/codesign --force --strip-disallowed-xattrs --sign "$LEGACY_IDENTITY" "$bundle"
    else
        [[ -f "$helper" ]] && /usr/bin/codesign --force --strip-disallowed-xattrs \
            --identifier "$FAN_HELPER_ID" --sign - "$helper"
        [[ -f "$adapter" ]] && /usr/bin/codesign --force --strip-disallowed-xattrs \
            --identifier "$NOW_PLAYING_ADAPTER_ID" --sign - "$adapter"
        /usr/bin/codesign --force --strip-disallowed-xattrs --sign - "$bundle"
    fi
    [[ -f "$helper" ]] && /usr/bin/codesign --verify --strict "$helper"
    [[ -f "$adapter" ]] && /usr/bin/codesign --verify --strict "$adapter"
    /usr/bin/codesign --verify --deep --strict "$bundle"
    echo "✓ Signature ready: $bundle"
}

if (( INSTALL && ! TEST )) && [[ "${YAYASSPACE_INSTALL_CHILD:-0}" != "1" ]]; then
    YAYASSPACE_INSTALL_CHILD=1 "$0" "$@"
    child_status=$?
    if (( child_status != 0 )); then
        exit "$child_status"
    fi
    finalize_installed_bundle_after_child "/Applications/$APP_NAME.app"
    exit 0
fi

# Prefer the macOS 26 SDK when present: the 27 SDK turns SwiftUI property wrappers
# into macros (SwiftUIMacros plugin) that the Command Line Tools cannot load yet.
PINNED_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    SDK="$(xcrun --show-sdk-path)"
elif [[ -d "$PINNED_SDK" ]]; then
    SDK="$PINNED_SDK"
else
    SDK="$(xcrun --show-sdk-path)"
fi
SDK_COMPAT_FLAGS=()
VM_STATISTICS_COMPAT_FLAGS=(-I Sources/VMStatisticsCompat)
HID_EVENT_SYSTEM_FLAGS=(-I Sources/HIDEventSystem)
if [[ "$SDK" == "$PINNED_SDK" ]]; then
    # Swift 6.4 can read the SDK 26 interfaces when given their compiler version.
    SDK_COMPAT_FLAGS=(-Xfrontend -interface-compiler-version -Xfrontend 6.3.2)
fi

# The defaults migrations under test need a real UserDefaults suite, and every
# suite leaves an empty plist in ~/Library/Preferences. The tests already clear
# the domains, but cfprefsd writes the emptied file back out around the time the
# process that owned it exits, so only a caller that outlives the run can remove
# them. `MetricsTests` keeps every suite name inside these two namespaces (a
# check in the test file holds it to that), which is what makes this sweep
# complete rather than a list to keep in step by hand.
discard_test_preferences() {
    local preferences="${1:-$HOME/Library/Preferences}" name attempt
    local survivors=0 quiet_passes=0
    # cfprefsd can recreate an emptied domain after the first removal. Require
    # two quiet checks, but keep a hard limit so persistent failures still fail CI.
    for attempt in {1..10}; do
        for name in "yayasspace.tests." "com.yahyaelghobashy.yayasspace.tests."; do
            rm -f "$preferences"/$name*.plist(N)
        done
        rm -f "$preferences/metrics-tests.plist"
        sleep 0.2
        survivors=$(find "$preferences" -maxdepth 1 \
            \( -name "yayasspace.tests.*.plist" -o -name "com.yahyaelghobashy.yayasspace.tests.*.plist" \
               -o -name "metrics-tests.plist" \) 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$survivors" == "0" ]]; then
            quiet_passes=$((quiet_passes + 1))
            if (( quiet_passes == 2 )); then return 0; fi
        else
            quiet_passes=0
        fi
    done
    echo "✗ test preferences did not settle in $preferences ($survivors remaining)" >&2
    return 1
}

# --test: compile and run the standalone unit tests (pure helpers only: metrics,
# Homebrew parsing, defaults, localization contracts; no app, no UI, no IOKit),
# then exit. Fast and deterministic; no XCTest needed.
if (( TEST )); then
    echo "▸ Building & running unit tests against $(basename "$SDK")…"
    rm -rf build
    mkdir -p build
    # The full app build below remains optimized and is the optimizer gate.
    # Unit assertions do not need optimization; avoiding it cuts most of the
    # test harness compile time without reducing the code the tests exercise.
    swiftc -Onone -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" \
        "${VM_STATISTICS_COMPAT_FLAGS[@]}" \
        Sources/YayasSpace/Services/Media/MediaSupport.swift \
        Sources/YayasSpace/Core/QuitProtectionSupport.swift \
        Sources/YayasSpace/Core/QuitProtectionStrings.swift \
        Sources/YayasSpace/Core/Defaults.swift \
        Sources/YayasSpace/Core/FeatureCatalog.swift \
        Sources/YayasSpace/Core/FeaturePresets.swift \
        Sources/YayasSpace/Core/FeatureHubStrings.swift \
        Sources/YayasSpace/Core/ShortcutSettingsStrings.swift \
        Sources/YayasSpace/Core/SettingsBackupSupport.swift \
        Sources/YayasSpace/Core/BackupStrings.swift \
        Sources/YayasSpace/Core/SnippetStrings.swift \
        Sources/YayasSpace/Core/BrightnessStrings.swift \
        Sources/YayasSpace/Core/MediaImageStrings.swift \
        Sources/YayasSpace/Core/QuickToggleStrings.swift \
        Sources/YayasSpace/Core/ScreenshotStrings.swift \
        Sources/YayasSpace/Core/RecentCaptureStrings.swift \
        Sources/YayasSpace/Core/RecorderStrings.swift \
        Sources/YayasSpace/Core/RecorderShareStrings.swift \
        Sources/YayasSpace/Core/CameraPreviewStrings.swift \
        Sources/YayasSpace/Core/ScratchpadStrings.swift \
        Sources/YayasSpace/Core/FinderRenameStrings.swift \
        Sources/YayasSpace/Core/CommandBarStrings.swift \
        Sources/YayasSpace/Core/FeedbackStrings.swift \
        Sources/YayasSpace/Core/RadialMenuStrings.swift \
        Sources/YayasSpace/Core/MenuBarAppearanceStrings.swift \
        Sources/YayasSpace/Core/AppAppearance.swift \
        Sources/YayasSpace/Core/AppearanceStrings.swift \
        Sources/YayasSpace/Core/BatteryTimeStrings.swift \
        Sources/YayasSpace/Core/KeepAwakeStrings.swift \
        Sources/YayasSpace/Core/BluetoothSleepStrings.swift \
        Sources/YayasSpace/Core/PermissionGuideStrings.swift \
        Sources/YayasSpace/Core/FanControlStrings.swift \
        Sources/YayasSpace/Services/FanControl/FanControlSupport.swift \
        Sources/YayasSpace/Services/Snippets/TextSnippetSupport.swift \
        Sources/YayasSpace/Sealed/NetworkPolicy.swift \
        Sources/YayasSpace/Services/RadialMenu/RadialMenuSupport.swift \
        Sources/YayasSpace/Services/QuickTools/ScratchpadSupport.swift \
        Sources/YayasSpace/Services/QuickTools/ScratchpadStore.swift \
        Sources/YayasSpace/Services/KillProcess/KillProcessSupport.swift \
        Sources/YayasSpace/Services/Recorder/RecorderSupport.swift \
        Sources/YayasSpace/Services/Recorder/RecordingSharingSupport.swift \
        Sources/YayasSpace/Services/PrivateFileStore.swift \
        Sources/YayasSpace/Services/Recorder/RecorderTakeStore.swift \
        Sources/YayasSpace/Services/Recorder/RecorderPresetImageStore.swift \
        Sources/YayasSpace/Services/Recorder/RecorderMotion.swift \
        Sources/YayasSpace/Services/Recorder/RecorderPointerTrack.swift \
        Sources/YayasSpace/Services/Recorder/RecorderTypingTrack.swift \
        Sources/YayasSpace/Services/Recorder/RecorderTimeline.swift \
        Sources/YayasSpace/Services/Recorder/RecorderTextOverlay.swift \
        Sources/YayasSpace/Services/Recorder/RecorderImageOverlay.swift \
        Sources/YayasSpace/Services/Recorder/RecorderBlurRegion.swift \
        Sources/YayasSpace/Services/Recorder/RecorderEditDocument.swift \
        Sources/YayasSpace/Core/AppInfo.swift \
        Sources/YayasSpace/Core/GlobalShortcut.swift \
        Sources/YayasSpace/Core/SymbolicHotKeys.swift \
        Sources/YayasSpace/Services/SystemShortcutTakeoverSupport.swift \
        Sources/YayasSpace/Core/Localization.swift \
        Sources/YayasSpace/Core/Localizations/Strings+*.swift \
        Sources/YayasSpace/Core/FeatureStrings.swift \
        Sources/YayasSpace/Core/KillProcessStrings.swift \
        Sources/YayasSpace/Core/WhatsAppDownloadStrings.swift \
        Sources/YayasSpace/Core/WhatsAppOrganizerStrings.swift \
        Sources/YayasSpace/Core/ReleaseNotes.swift \
        Sources/YayasSpace/Core/URLCleaning.swift \
        Sources/YayasSpace/Services/GeneralPasteboardAccess.swift \
        Sources/YayasSpace/Services/Audio/MixerRoutingSupport.swift \
        Sources/YayasSpace/Services/Audio/MusicLaunchSupport.swift \
        Sources/YayasSpace/Services/Bluetooth/BluetoothSleepSupport.swift \
        Sources/YayasSpace/UI/MenuPanel/MixerPercentNativeTextField.swift \
        Sources/YayasSpace/Services/Audio/BoostLimiter.swift \
        Sources/YayasSpace/Services/Audio/MixerRender.swift \
        Sources/YayasSpace/Services/Audio/PreciseVolumeRollerSupport.swift \
        Sources/YayasSpace/Services/DockPreview/DockPreviewSupport.swift \
        Sources/YayasSpace/Services/Homebrew/HomebrewSupport.swift \
        Sources/YayasSpace/Services/AppUpdates/AppUpdatesSupport.swift \
        Sources/YayasSpace/Core/AppUpdateStrings.swift \
        Sources/YayasSpace/Core/DiskImageInstallerStrings.swift \
        Sources/YayasSpace/Services/DiskImageInstaller/DiskImageInstallerSupport.swift \
        Sources/YayasSpace/Services/Clipboard/ClipboardHistorySupport.swift \
        Sources/YayasSpace/Services/Clipboard/ClipboardAutoClearSupport.swift \
        Sources/YayasSpace/Services/AutoQuit/AutoQuitSupport.swift \
        Sources/YayasSpace/Services/Shelf/ShelfSupport.swift \
        Sources/YayasSpace/Services/Finder/FinderRenameSupport.swift \
        Sources/YayasSpace/Services/Update/UpdateServiceSupport.swift \
        Sources/YayasSpace/Services/InstalledApps.swift \
        Sources/YayasSpace/Services/LaunchAtLoginSupport.swift \
        Sources/YayasSpace/UI/Settings/SettingsSearchSupport.swift \
        Sources/YayasSpace/UI/Settings/FeatureVisibilitySupport.swift \
        Sources/YayasSpace/App/MenuBarSpacingSupport.swift \
        Sources/YayasSpace/App/StatusItemAnchorSupport.swift \
        Sources/YayasSpace/Services/DockClick/DockClickSupport.swift \
        Sources/YayasSpace/Services/Finder/CutPasteProgressSupport.swift \
        Sources/YayasSpace/Services/Finder/CutPastePrivilegeSupport.swift \
        Sources/YayasSpace/Services/Finder/FinderPasteImageSupport.swift \
        Sources/YayasSpace/Services/MiddleClick/MiddleClickSupport.swift \
        Sources/YayasSpace/Services/MouseNavigation/MouseNavigationSupport.swift \
        Sources/YayasSpace/Services/MouseButtons/MouseButtonShortcutSupport.swift \
        Sources/YayasSpace/Services/MouseButtons/MouseSpacesGestureSupport.swift \
        Sources/YayasSpace/Services/MouseClickDebounce/MouseClickDebounceSupport.swift \
        Sources/YayasSpace/Services/MouseExceptions/MouseAppExceptionSupport.swift \
        Sources/YayasSpace/Services/MouseExceptions/MouseAppExceptions.swift \
        Sources/YayasSpace/Services/WindowServerSupport.swift \
        Sources/YayasSpace/Core/MouseButtonStrings.swift \
        Sources/YayasSpace/Core/MouseClickDebounceStrings.swift \
        Sources/YayasSpace/Core/MouseExceptionStrings.swift \
        Sources/YayasSpace/Core/ClipboardIgnoredAppsStrings.swift \
        Sources/YayasSpace/Core/WindowPreviewExclusionStrings.swift \
        Sources/YayasSpace/Core/DiskExclusionStrings.swift \
        Sources/YayasSpace/Core/SwitcherAppRulesStrings.swift \
        Sources/YayasSpace/Services/QuickTools/QuickToolsSupport.swift \
        Sources/YayasSpace/Services/CommandBar/CommandBarSupport.swift \
        Sources/YayasSpace/Services/CommandBar/CommandBarPreferences.swift \
        Sources/YayasSpace/Services/CommandBar/CommandBarMath.swift \
        Sources/YayasSpace/Services/CommandBar/CommandBarUnits.swift \
        Sources/YayasSpace/Services/CommandBar/CommandBarEmoji.swift \
        Sources/YayasSpace/Services/CommandBar/CommandBarLinks.swift \
        Sources/YayasSpace/Services/CommandBar/CommandBarDates.swift \
        Sources/YayasSpace/Services/CommandBar/CommandBarRowShortcuts.swift \
        Sources/YayasSpace/Services/CommandBar/CommandBarSystemSettingsSupport.swift \
        Sources/YayasSpace/Services/CommandBar/CommandBarFileSearchSupport.swift \
        Sources/YayasSpace/Services/CommandBar/CommandBarQueryMemory.swift \
        Sources/YayasSpace/Services/SpotlightNamesSupport.swift \
        Sources/YayasSpace/Services/QuickTools/MicMuteSupport.swift \
        Sources/YayasSpace/Services/QuickTools/QuickTogglesSupport.swift \
        Sources/YayasSpace/Services/QuickTools/ScreenshotCapturePolicy.swift \
        Sources/YayasSpace/Services/QuickTools/ScreenshotSupport.swift \
        Sources/YayasSpace/Services/QuickTools/RecentCaptureStore.swift \
        Sources/YayasSpace/Services/QuickTools/ScreenshotSharingSupport.swift \
        Sources/YayasSpace/Services/QuickTools/WindowActivationPolicy.swift \
        Sources/YayasSpace/Services/KeyboardDebounce/KeyboardDebounceSupport.swift \
        Sources/YayasSpace/Services/SuperKey/SuperKeySupport.swift \
        Sources/YayasSpace/Services/SuperKey/SuperKeyMappingGuard.swift \
        Sources/YayasSpace/Core/SuperKeyStrings.swift \
        Sources/YayasSpace/Services/SessionActivity.swift \
        Sources/YayasSpace/Services/SessionActivitySupport.swift \
        Sources/YayasSpace/Services/ScrollWheelSupport.swift \
        Sources/YayasSpace/Services/SmoothScrollSupport.swift \
        Sources/YayasSpace/Services/MouseAcceleration/MouseAccelerationSupport.swift \
        Sources/YayasSpace/Services/FocusFollowsMouse/FocusFollowsMouseSupport.swift \
        Sources/YayasSpace/Services/Switcher/SwitcherModels.swift \
        Sources/YayasSpace/Services/Switcher/SwitcherSupport.swift \
        Sources/YayasSpace/Services/Switcher/SpaceHopSupport.swift \
        Sources/YayasSpace/Services/Switcher/WindowUseOrder.swift \
        Sources/YayasSpace/Services/Metrics/MetricFormat.swift \
        Sources/YayasSpace/Services/Metrics/VMStatisticsDecoder.swift \
        Sources/YayasSpace/Services/KeepAwakeAutomationSupport.swift \
        Sources/YayasSpace/Services/SudoersSupport.swift \
        Sources/YayasSpace/Services/Metrics/BatteryTimeSupport.swift \
        Sources/YayasSpace/Services/BoundedProcessRunner.swift \
        Sources/YayasSpace/Services/DetachedProcess.swift \
        Sources/YayasSpace/Services/ShellSupport.swift \
        Sources/YayasSpace/Services/Metrics/NetworkProcessSupport.swift \
        Sources/YayasSpace/Services/Metrics/NetworkSampler.swift \
        Sources/YayasSpace/Services/Metrics/PeripheralBatterySupport.swift \
        Sources/YayasSpace/Services/Metrics/DiskSupport.swift \
        Sources/YayasSpace/Services/Metrics/MonitorSamplingPolicy.swift \
        Sources/YayasSpace/Services/Metrics/MaxCapacityProbe.swift \
        Sources/YayasSpace/Services/Metrics/TemperatureSensorSelector.swift \
        Sources/YayasSpace/Services/Metrics/SustainedAlertGate.swift \
        Sources/YayasSpace/Services/WindowLayout/WindowLayoutSupport.swift \
        Sources/YayasSpace/Services/WindowLayout/WindowGestureSupport.swift \
        Sources/YayasSpace/Core/WindowDirectionalStrings.swift \
        Sources/YayasSpace/Services/CleaningMode/CleaningUnlockCounter.swift \
        Sources/YayasSpace/Services/Display/ExtraBrightnessSupport.swift \
        Sources/YayasSpace/Services/Display/BrightnessSupport.swift \
        Sources/YayasSpace/Services/Cleaner/CleanerSupport.swift \
        Sources/YayasSpace/Services/Cleaner/CleanerPolicy.swift \
        Sources/YayasSpace/Services/Cleaner/CleanerSchedule.swift \
        Sources/YayasSpace/Services/Uninstall/UninstallerSupport.swift \
        Sources/YayasSpace/Services/ManagedDownloads/WhatsAppDownloadSupport.swift \
        Tests/MetricsTests.swift \
        Tests/RecentCaptureStoreTests.swift \
        Tests/RecorderPresetImageStoreTests.swift \
        -o build/metrics-tests
    # `set -e` would end the script on a failing run before the sweep below.
    test_status=0
    ./build/metrics-tests || test_status=$?
    ./Tests/PreferenceCleanupTests.sh || test_status=1
    discard_test_preferences || test_status=1
    exit $test_status
fi

echo "▸ Compiling ($BUILD_CONFIGURATION) against $(basename "$SDK")…"
APP_SOURCES=(Sources/YayasSpace/**/*.swift)
if (( DEV )); then
    APP_OBJECT_DIR="build/objects/$EXECUTABLE"
    mkdir -p build "$APP_OBJECT_DIR"
    APP_OUTPUT_FILE_MAP="$APP_OBJECT_DIR/output-file-map.json"
    write_swift_output_file_map "$APP_OUTPUT_FILE_MAP" "$APP_OBJECT_DIR" "${APP_SOURCES[@]}"
    swiftc "${APP_OPTIMIZATION_FLAGS[@]}" -incremental -j "$(sysctl -n hw.logicalcpu)" \
        -output-file-map "$APP_OUTPUT_FILE_MAP" \
        -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" "${VM_STATISTICS_COMPAT_FLAGS[@]}" "${HID_EVENT_SYSTEM_FLAGS[@]}" \
        "${BUILD_VARIANT_FLAGS[@]}" \
        "${APP_SOURCES[@]}" -o "build/$EXECUTABLE"
else
    rm -rf build
    mkdir -p build
    swiftc "${APP_OPTIMIZATION_FLAGS[@]}" -target "$TARGET" -sdk "$SDK" \
        "${SDK_COMPAT_FLAGS[@]}" "${VM_STATISTICS_COMPAT_FLAGS[@]}" "${HID_EVENT_SYSTEM_FLAGS[@]}" "${BUILD_VARIANT_FLAGS[@]}" \
        "${APP_SOURCES[@]}" -o "build/$EXECUTABLE"
fi

echo "▸ Compiling protected fan helper…"
swiftc -O -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" "${BUILD_VARIANT_FLAGS[@]}" \
    Sources/YayasSpace/Services/FanControl/FanControlSupport.swift \
    Sources/YayasSpace/Services/FanControl/FanControlXPC.swift \
    Sources/YayasSpace/Services/SystemMonitor/SMCClient.swift \
    Sources/YayasSpace/Services/Metrics/TemperatureSensorSelector.swift \
    Sources/YayasSpace/Services/FanControl/FanControlHardware.swift \
    Sources/FanControlHelper/main.swift \
    -o "build/$FAN_HELPER_ID"
"build/$FAN_HELPER_ID" --selftest

echo "▸ Compiling Now Playing adapter…"
swiftc -O -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" -emit-library \
    -module-name YayasSpaceNowPlaying \
    Sources/NowPlayingAdapter/NowPlayingAdapter.swift \
    -o "build/$NOW_PLAYING_ADAPTER"

echo "▸ Generating app icon…"
swift Tools/MakeIcon.swift build/AppIcon.iconset
xattr -c -r build/AppIcon.iconset build/AppIcon.icns build/MenuBarIcon.png build/MenuBarIcon@2x.png build/BrandMark.png 2>/dev/null || true
ACTOOL_BIN="$(xcrun --find actool 2>/dev/null || true)"
ICON_TMP="$(mktemp -d)"
ADAPTIVE_SKIP=""
if [[ -z "$ACTOOL_BIN" ]]; then
    ADAPTIVE_SKIP="actool not found (adaptive icons need Xcode 26+)"
else
    echo "▸ Compiling adaptive icon catalog…"
    # actool crashes on File Provider-synced paths, so compile a local copy.
    ditto "Resources/Brand/AppIcon.icon" "$ICON_TMP/AppIcon.icon"
    # Xcode 27 beta actool requires the --compile target directory to already exist.
    mkdir -p "$ICON_TMP/catalog"
    if "$ACTOOL_BIN" "$ICON_TMP/AppIcon.icon" \
            --compile "$ICON_TMP/catalog" \
            --app-icon AppIcon \
            --platform macosx \
            --target-device mac \
            --minimum-deployment-target 14.0 \
            --enable-on-demand-resources NO \
            --output-partial-info-plist "$ICON_TMP/partial-info.plist" \
            >"$ICON_TMP/actool.log" 2>&1 && [[ -s "$ICON_TMP/catalog/Assets.car" ]]; then
        mv "$ICON_TMP/catalog/Assets.car" build/Assets.car
    else
        ADAPTIVE_SKIP="actool could not compile the catalog"
    fi
fi
if [[ -n "$ADAPTIVE_SKIP" ]]; then
    cp "$ICON_TMP/actool.log" build/actool-failure.log 2>/dev/null || true
    echo "  adaptive icon skipped: $ADAPTIVE_SKIP (Dock falls back to AppIcon.icns)"
fi
echo "▸ Assembling and signing bundle…"
STAGE_TMP="$(mktemp -d)"
STAGE="$STAGE_TMP/$APP_NAME.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources" \
    "$STAGE/Contents/Library/LaunchDaemons" "$STAGE/Contents/Library/LaunchServices"
cp "build/$EXECUTABLE" "$STAGE/Contents/MacOS/$EXECUTABLE"
cp "build/$FAN_HELPER_ID" "$STAGE/Contents/Library/LaunchServices/$FAN_HELPER_ID"
mkdir -p "$STAGE/Contents/Frameworks"
cp "build/$NOW_PLAYING_ADAPTER" "$STAGE/Contents/Frameworks/$NOW_PLAYING_ADAPTER"
cp Resources/now-playing.pl "$STAGE/Contents/Resources/now-playing.pl"
cp Resources/com.yahyaelghobashy.yayasspace.fan-control.plist \
    "$STAGE/Contents/Library/LaunchDaemons/$FAN_HELPER_ID.plist"
cp Resources/Info.plist "$STAGE/Contents/Info.plist"
cp CHANGELOG.md "$STAGE/Contents/Resources/CHANGELOG.md"
for lproj in Resources/*.lproj(N); do
    cp -R "$lproj" "$STAGE/Contents/Resources/"
done
if (( DEV )); then
    # A distinct identity so the Developer build installs and runs next to the
    # official app, with its own permissions, preferences and login item.
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.yahyaelghobashy.yayasspace.dev" "$STAGE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName Yaya's Space (Developer)" "$STAGE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Yaya's Space (Developer)" "$STAGE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $EXECUTABLE" "$STAGE/Contents/Info.plist"
    # Sealed fork: the Developer variant carries its own version so About and
    # the update check can tell it apart from the upstream release it tracks.
    SEALED_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)-sealed.2"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SEALED_VERSION" "$STAGE/Contents/Info.plist"
    echo "  sealed version: $SEALED_VERSION"
    FAN_PLIST="$STAGE/Contents/Library/LaunchDaemons/$FAN_HELPER_ID.plist"
    /usr/libexec/PlistBuddy -c "Set :Label $FAN_HELPER_ID" "$FAN_PLIST"
    /usr/libexec/PlistBuddy -c "Set :BundleProgram Contents/Library/LaunchServices/$FAN_HELPER_ID" "$FAN_PLIST"
    /usr/libexec/PlistBuddy -c "Delete :MachServices:com.yahyaelghobashy.yayasspace.fan-control" "$FAN_PLIST"
    /usr/libexec/PlistBuddy -c "Add :MachServices:$FAN_HELPER_ID bool true" "$FAN_PLIST"
    # Stamp the source commit + build time so the running dev app shows (in About)
    # exactly which code it was compiled from. Lets you verify it matches HEAD before
    # testing, instead of unknowingly running a stale build. Dev-only; never shipped.
    SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    [[ -n "$(git status --porcelain 2>/dev/null)" ]] && SHA="$SHA-dirty"
    /usr/libexec/PlistBuddy -c "Add :YayasSpaceBuildCommit string '$SHA · $(date '+%Y-%m-%d %H:%M')'" "$STAGE/Contents/Info.plist"
    echo "  stamped dev build: $SHA"
fi
FAN_HELPER_VERSION="$(
    export LC_ALL=C
    /usr/bin/shasum -a 256 \
        "$STAGE/Contents/Library/LaunchServices/$FAN_HELPER_ID" \
        "$STAGE/Contents/Library/LaunchDaemons/$FAN_HELPER_ID.plist" \
        | /usr/bin/awk '{print $1}' | /usr/bin/shasum -a 256 \
        | /usr/bin/awk '{print $1}'
)"
/usr/libexec/PlistBuddy -c "Add :YayasSpaceFanControlHelperVersion string '$FAN_HELPER_VERSION'" \
    "$STAGE/Contents/Info.plist"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"
cp build/AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"
cp build/MenuBarIcon.png build/MenuBarIcon@2x.png build/BrandMark.png "$STAGE/Contents/Resources/"
if [[ -f build/Assets.car ]]; then
    cp build/Assets.car "$STAGE/Contents/Resources/Assets.car"
fi
if [[ -d Resources/Gifs ]]; then
    mkdir -p "$STAGE/Contents/Resources/Gifs"
    cp Resources/Gifs/*.gif "$STAGE/Contents/Resources/Gifs/"
fi
if [[ -d Resources/Images ]]; then
    mkdir -p "$STAGE/Contents/Resources/Images"
    cp Resources/Images/* "$STAGE/Contents/Resources/Images/"
fi
xattr -c -r "$STAGE" 2>/dev/null || true

# Signing, in order of preference:
#   1. Developer ID Application — the real, Apple-issued identity used for
#      notarized releases. Signed with the hardened runtime (required for
#      notarization), the app's entitlements and a secure timestamp. Gives a
#      stable, team-based designated requirement, so permissions persist across
#      updates AND Gatekeeper shows no "unverified developer" warning.
#   2. "Yaya's Space Utils Signing" — the legacy stable self-signed identity, kept
#      as a fallback so contributors without a Developer ID still get a constant
#      designated requirement across their local builds.
#   3. Ad-hoc — fresh clone with no identity at all.
DEVID="$(developer_id_identity)"
codesign_app() {
    local target="$1"
    if [[ -n "$DEVID" ]]; then
        codesign_with_timestamp_retry --force --strip-disallowed-xattrs --options runtime --timestamp \
            --entitlements "$ENTITLEMENTS" --sign "$DEVID" "$target"
    elif legacy_identity_installed; then
        codesign --force --strip-disallowed-xattrs --sign "$LEGACY_IDENTITY" "$target"
    else
        codesign --force --strip-disallowed-xattrs --sign - "$target"
    fi
}

codesign_fan_helper() {
    local target="$1"
    if [[ -n "$DEVID" ]]; then
        codesign_with_timestamp_retry --force --strip-disallowed-xattrs --options runtime --timestamp \
            --identifier "$FAN_HELPER_ID" --sign "$DEVID" "$target"
    elif legacy_identity_installed; then
        codesign --force --strip-disallowed-xattrs --identifier "$FAN_HELPER_ID" \
            --sign "$LEGACY_IDENTITY" "$target"
    else
        codesign --force --strip-disallowed-xattrs --identifier "$FAN_HELPER_ID" --sign - "$target"
    fi
}

codesign_now_playing_adapter() {
    local target="$1"
    if [[ -n "$DEVID" ]]; then
        codesign_with_timestamp_retry --force --strip-disallowed-xattrs --options runtime --timestamp \
            --identifier "$NOW_PLAYING_ADAPTER_ID" --sign "$DEVID" "$target"
    elif legacy_identity_installed; then
        codesign --force --strip-disallowed-xattrs --identifier "$NOW_PLAYING_ADAPTER_ID" \
            --sign "$LEGACY_IDENTITY" "$target"
    else
        codesign --force --strip-disallowed-xattrs --identifier "$NOW_PLAYING_ADAPTER_ID" --sign - "$target"
    fi
}

sign_bundle() {
    local bundle="$1"
    local executable="$bundle/Contents/MacOS/$EXECUTABLE"
    local helper="$bundle/Contents/Library/LaunchServices/$FAN_HELPER_ID"
    local adapter="$bundle/Contents/Frameworks/$NOW_PLAYING_ADAPTER"

    if [[ -n "$DEVID" ]]; then
        echo "  signing with Developer ID (hardened runtime): $DEVID"
    elif legacy_identity_installed; then
        echo "  signing with legacy self-signed identity: $LEGACY_IDENTITY"
    else
        echo "  signing ad-hoc (no identity installed — run Tools/setup-signing.sh)"
    fi
    [[ -f "$helper" ]] && codesign_fan_helper "$helper"
    [[ -f "$adapter" ]] && codesign_now_playing_adapter "$adapter"
    codesign_app "$bundle"

    # If local filesystem metadata invalidates the first signature, sign once
    # more. The installed Developer bundle is signed again after the final copy.
    if ! codesign --verify --deep --strict "$bundle" >/dev/null 2>&1; then
        echo "  re-signing after filesystem metadata settled"
        xattr -c -r "$bundle" 2>/dev/null || true
        [[ -f "$helper" ]] && codesign_fan_helper "$helper"
        [[ -f "$adapter" ]] && codesign_now_playing_adapter "$adapter"
        codesign_app "$bundle"
    fi
    [[ -f "$executable" ]] && codesign --verify --strict "$executable"
    [[ -f "$helper" ]] && codesign --verify --strict "$helper"
    [[ -f "$adapter" ]] && codesign --verify --strict "$adapter"
    codesign --verify --deep --strict "$bundle"
}

sign_installed_bundle() {
    local bundle="$1"
    wait_for_install_metadata "$bundle"
    sign_bundle "$bundle"
}

sign_bundle "$STAGE"

process_is_running() {
    local proc="$1"
    if (( ${#proc} > 15 )); then
        pgrep -f "/Contents/MacOS/$proc" >/dev/null 2>&1
    else
        pgrep -x "$proc" >/dev/null 2>&1
    fi
}

stop_process() {
    local proc="$1"
    if (( ${#proc} > 15 )); then
        pkill -f "/Contents/MacOS/$proc" 2>/dev/null || true
    else
        pkill -x "$proc" 2>/dev/null || true
    fi
    for _ in {1..50}; do
        if ! process_is_running "$proc"; then
            return 0
        fi
        sleep 0.1
    done
    echo "✗ $proc is still running — quit it and retry" >&2
    return 1
}

wait_for_install_metadata() {
    local bundle="$1"
    local missing
    for _ in {1..50}; do
        missing=0
        while IFS= read -r file; do
            if ! xattr -p com.apple.provenance "$file" >/dev/null 2>&1; then
                missing=1
                break
            fi
        done < <(find "$bundle/Contents" -type f ! -path "*/_CodeSignature/*")
        if (( missing == 0 )); then
            return 0
        fi
        sleep 0.1
    done
}

mkdir -p "build/stage"
BUILD_STAGE="build/stage/$APP_NAME.app"
rm -rf "$BUILD_STAGE"
ditto --noextattr --noqtn "$STAGE" "$BUILD_STAGE"
xattr -c -r "$BUILD_STAGE" 2>/dev/null || true
if ! codesign --verify --deep --strict "$BUILD_STAGE" >/dev/null 2>&1; then
    if xattr -lr "$BUILD_STAGE" 2>/dev/null | grep -Eq 'com\.apple\.(FinderInfo|ResourceFork|provenance|fileprovider)'; then
        echo "  build/stage copy has local filesystem metadata; temp bundle was verified"
    else
        codesign --verify --deep --strict "$BUILD_STAGE"
    fi
fi
echo "✓ Bundle ready: $BUILD_STAGE"
if (( DEV )); then
    # Sealed fork: keep a finished copy outside build/ so it survives cleanups.
    mkdir -p dist
    DIST_BUNDLE="dist/$APP_NAME.app"
    rm -rf "$DIST_BUNDLE"
    ditto --noextattr --noqtn "$STAGE" "$DIST_BUNDLE"
    xattr -c -r "$DIST_BUNDLE" 2>/dev/null || true
    echo "✓ Developer bundle kept at: $DIST_BUNDLE"
fi

if (( INSTALL )); then
    echo "▸ Installing into /Applications…"
    stop_process "$EXECUTABLE"
    INSTALL_DEST="/Applications/$APP_NAME.app"
    rm -rf "$INSTALL_DEST"
    ditto --noextattr --noqtn "$STAGE" "$INSTALL_DEST"
    sign_installed_bundle "$INSTALL_DEST"
    echo "✓ Installed: $INSTALL_DEST"
fi
