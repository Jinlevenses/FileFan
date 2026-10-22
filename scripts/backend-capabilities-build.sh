#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
SDK="$PROJECT_DIR/artifacts/toolchains/dotnet/dotnet"
BACKEND="$PROJECT_DIR/artifacts/runtime/Filee/Filee-1.12.0-osx-arm64/Filee.app/Contents/MacOS"
OUTPUT="$PROJECT_DIR/.build/backend-capabilities"
export DOTNET_CLI_HOME="$PROJECT_DIR/artifacts/toolchains/home"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
export DOTNET_GENERATE_ASPNET_CERTIFICATE=false
"$SDK" build "$PROJECT_DIR/scripts/backend-capabilities/BackendCapabilities.csproj" -c Release -o "$OUTPUT" -p:BackendDirectory="$BACKEND" --ignore-failed-sources
cp "$BACKEND/filee-cli.runtimeconfig.json" "$OUTPUT/filefan-caps.runtimeconfig.json"
cp "$BACKEND/filee-cli.deps.json" "$OUTPUT/filefan-caps.deps.json"
print "Capability bridge built: $OUTPUT"
