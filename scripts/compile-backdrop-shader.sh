#!/bin/bash
# Compile a Shadertoy-style GLSL shader (Ghostty custom-shader format) into
# Metal Shading Language for use with the `backdrop.shaderPath` setting.
#
# Usage: scripts/compile-backdrop-shader.sh <shader.glsl> [output-name]
#
# Output: ~/.config/cmux/backdrops/<output-name>.metal
#
# Requires: glslangValidator + spirv-cross (brew install glslang spirv-cross)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX_SRC="$REPO_ROOT/ghostty/src/renderer/shaders/shadertoy_prefix.glsl"

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <shader.glsl> [output-name]" >&2
  exit 1
fi

SHADER="$1"
NAME="${2:-$(basename "${SHADER%.glsl}")}"
OUT_DIR="$HOME/.config/cmux/backdrops"
OUT="$OUT_DIR/$NAME.metal"

for tool in glslangValidator spirv-cross; do
  command -v "$tool" >/dev/null || {
    echo "error: $tool not found (brew install glslang spirv-cross)" >&2
    exit 1
  }
done
[[ -f "$SHADER" ]] || { echo "error: shader not found: $SHADER" >&2; exit 1; }
[[ -f "$PREFIX_SRC" ]] || { echo "error: ghostty submodule prefix missing: $PREFIX_SRC" >&2; exit 1; }

mkdir -p "$OUT_DIR"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Ghostty's prefix targets OpenGL fragment coordinates (origin bottom-left);
# Metal's are top-left, so flip Y in the wrapper main().
sed 's/void main() { mainImage (_fragColor, gl_FragCoord.xy); }/void main() { mainImage (_fragColor, vec2(gl_FragCoord.x, iResolution.y - gl_FragCoord.y)); }/' \
  "$PREFIX_SRC" > "$TMP_DIR/prefix.glsl"

cat "$TMP_DIR/prefix.glsl" "$SHADER" > "$TMP_DIR/composed.frag"
glslangValidator -V "$TMP_DIR/composed.frag" -S frag -o "$TMP_DIR/shader.spv"
spirv-cross --msl --msl-version 20300 "$TMP_DIR/shader.spv" --output "$OUT"

echo "compiled: $OUT"
echo "enable it in ~/.config/cmux/cmux.json:"
echo "  \"backdrop\": { \"shaderPath\": \"$OUT\" }"
