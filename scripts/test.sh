#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/swift-module-cache"
DEVELOPER_DIR_PATH=$(xcode-select -p)
FRAMEWORK_DIR="$DEVELOPER_DIR_PATH/Library/Developer/Frameworks"
RUNTIME_DIR="$DEVELOPER_DIR_PATH/Library/Developer/usr/lib"
if [[ ! -d "$FRAMEWORK_DIR/Testing.framework" ]]; then
    FRAMEWORK_DIR="$DEVELOPER_DIR_PATH/Platforms/MacOSX.platform/Developer/Library/Frameworks"
    RUNTIME_DIR="$DEVELOPER_DIR_PATH/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx"
fi
test -d "$FRAMEWORK_DIR/Testing.framework"
swift test --disable-xctest --cache-path .build/cache --config-path .build/config --security-path .build/security --manifest-cache local --disable-sandbox \
    -Xswiftc -F -Xswiftc "$FRAMEWORK_DIR" \
    -Xlinker -rpath -Xlinker "$FRAMEWORK_DIR" \
    -Xlinker -rpath -Xlinker "$RUNTIME_DIR" "$@"
