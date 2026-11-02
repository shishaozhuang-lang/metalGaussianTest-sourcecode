#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h}"
project="$repo_dir/SampleApp/MetalSplatter_SampleApp.xcodeproj"
scheme="MetalSplatter SampleApp"
output_dir="$repo_dir/dist/ios"
derived_data="$repo_dir/.ios-derived"
mode="${1:-simulator}"

mkdir -p "$output_dir"

if ! xcodebuild -showsdks | grep -q "iphoneos"; then
  echo "The iOS Platform is not installed in the selected Xcode." >&2
  echo "Install it in Xcode → Settings → Components → iOS, then rerun this script." >&2
  exit 3
fi

archive_device() {
  archive_path="$output_dir/MetalSplatter.xcarchive"
  xcodebuild \
    -project "$project" \
    -scheme "$scheme" \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "$archive_path" \
    DEVELOPMENT_TEAM="$team_id" \
    PRODUCT_BUNDLE_IDENTIFIER="$bundle_id" \
    clean archive
}

case "$mode" in
  simulator)
    if ! xcrun simctl list runtimes | grep -q "iOS"; then
      echo "No iOS Simulator runtime is installed." >&2
      echo "Install one in Xcode → Settings → Components → iOS, then rerun this script." >&2
      exit 3
    fi
    xcodebuild \
      -project "$project" \
      -scheme "$scheme" \
      -configuration Release \
      -destination "generic/platform=iOS Simulator" \
      -derivedDataPath "$derived_data" \
      CODE_SIGNING_ALLOWED=NO \
      build

    app="$derived_data/Build/Products/Release-iphonesimulator/MetalSplatter SampleApp.app"
    ditto "$app" "$output_dir/MetalSplatter-Simulator.app"
    echo "Simulator app: $output_dir/MetalSplatter-Simulator.app"
    ;;

  archive|ipa)
    team_id="${DEVELOPMENT_TEAM:-}"
    bundle_id="${PRODUCT_BUNDLE_IDENTIFIER:-}"
    if [[ -z "$team_id" || -z "$bundle_id" ]]; then
      echo "Archive requires DEVELOPMENT_TEAM and PRODUCT_BUNDLE_IDENTIFIER." >&2
      echo "Example: DEVELOPMENT_TEAM=ABCDE12345 PRODUCT_BUNDLE_IDENTIFIER=com.example.metalsplatter ./package-ios.sh archive" >&2
      exit 2
    fi

    archive_device

    echo "Device archive: $archive_path"
    if [[ "$mode" == "ipa" ]]; then
      method="${EXPORT_METHOD:-development}"
      export_options="$output_dir/ExportOptions.plist"
      cp "$repo_dir/SampleApp/ExportOptions.plist" "$export_options"
      /usr/libexec/PlistBuddy -c "Set :teamID $team_id" "$export_options"
      /usr/libexec/PlistBuddy -c "Set :method $method" "$export_options"
      xcodebuild -exportArchive \
        -archivePath "$archive_path" \
        -exportPath "$output_dir/export" \
        -exportOptionsPlist "$export_options"
      echo "IPA output: $output_dir/export"
    else
      echo "Open it with: open '$archive_path'"
      echo "Then use Xcode Organizer → Distribute App, or run the ipa mode."
    fi
    ;;

  *)
    echo "Usage: ./package-ios.sh [simulator|archive|ipa]" >&2
    exit 2
    ;;
esac
