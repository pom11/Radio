#!/bin/bash
# DEV TOOL: Regenerate App Intents metadata after modifying RadioIntents.swift
# Requires full Xcode (not just CLT). Output goes to Resources/Metadata.appintents/
# The pre-compiled metadata is shipped in the repo — users don't need this.

set -e

OUTPUT_DIR="${1:-.build/appintents}"
SOURCES_FILE=".build/arm64-apple-macosx/release/Radio.build/sources"

# Requires full Xcode (not just CLT) for appintentsmetadataprocessor
if ! xcrun --find appintentsmetadataprocessor >/dev/null 2>&1; then
    echo "Skipping: appintentsmetadataprocessor not found (requires Xcode, not just CLT)" >&2
    exit 1
fi

# Auto-detect paths
TOOLCHAIN=$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain
SDK=$(xcrun --show-sdk-path)
XCODE_VERSION=$(xcodebuild -version 2>/dev/null | head -1 | awk '{print $2}')
XCODE_VERSION="${XCODE_VERSION:-16.0}"

# Protocols to extract const values for
PROTOCOLS_FILE=$(mktemp)
echo '["AppIntent", "AppEntity", "AppShortcutsProvider", "EntityStringQuery", "EntityQuery", "AppEnum", "IntentValueQuery", "_IntentValue", "DynamicOptionsProvider"]' > "$PROTOCOLS_FILE"

CONST_DIR=$(mktemp -d)

# Generate const values for each source file
while IFS= read -r src; do
    [ -z "$src" ] && continue
    name=$(basename "$src" .swift)
    other_sources=$(grep -v "^${src}$" "$SOURCES_FILE" | tr '\n' ' ')
    xcrun swift-frontend -frontend -c \
        -primary-file "$src" \
        $other_sources \
        -emit-const-values-path "${CONST_DIR}/${name}.swiftconstvalues" \
        -const-gather-protocols-file "$PROTOCOLS_FILE" \
        -o "${CONST_DIR}/${name}.o" \
        -target arm64-apple-macosx14.0 \
        -sdk "$SDK" \
        -swift-version 5 \
        -I ".build/arm64-apple-macosx/release/Modules" \
        -DSWIFT_PACKAGE -DSWIFT_MODULE_RESOURCE_BUNDLE_AVAILABLE \
        -module-name Radio \
        -parse-as-library 2>/dev/null
done < "$SOURCES_FILE"

# Create file lists
ls -1 "${CONST_DIR}"/*.swiftconstvalues > "${CONST_DIR}/const-vals.list"

mkdir -p "$OUTPUT_DIR"

# Run metadata processor
xcrun appintentsmetadataprocessor \
    --output "$OUTPUT_DIR" \
    --toolchain-dir "$TOOLCHAIN" \
    --module-name Radio \
    --sdk-root "$SDK" \
    --xcode-version "$XCODE_VERSION" \
    --platform-family macOS \
    --deployment-target 14.0 \
    --target-triple arm64-apple-macosx14.0 \
    --source-file-list "$SOURCES_FILE" \
    --swift-const-vals-list "${CONST_DIR}/const-vals.list" 2>&1

# Cleanup
rm -rf "$CONST_DIR" "$PROTOCOLS_FILE"

echo "Metadata generated at: ${OUTPUT_DIR}/Metadata.appintents"
