#!/bin/bash
# Compile GLSL shaders to SPIR-V for Vulkan
# Requires glslc (from Vulkan SDK or shaderc package)
#
# NOTE: This script is provided for manual shader compilation and debugging.
# The main build system (zig build) automatically compiles shaders as a
# dependency, so you typically don't need to run this script manually.
#
# The build.zig shader compilation is triggered automatically when building
# any Linux executable that @embedFile's the .spv files.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Compiling shaders to SPIR-V..."

# Check for glslc
if ! command -v glslc &> /dev/null; then
    echo "Error: glslc not found. Install vulkan-tools or shaderc package."
    echo "  Ubuntu/Debian: sudo apt install glslc"
    echo "  Arch: sudo pacman -S shaderc"
    echo "  Or install Vulkan SDK from https://vulkan.lunarg.com/"
    exit 1
fi

# Note: We intentionally don't use -O (optimization) flag to match build.zig behavior.
# Some GPU drivers have issues with optimized SPIR-V, and the performance difference
# is negligible for these simple shaders.

# Compile unified shader (quads and shadows)
echo "  unified.vert -> unified.vert.spv"
glslc -fshader-stage=vertex -o unified.vert.spv unified.vert

echo "  unified.frag -> unified.frag.spv"
glslc -fshader-stage=fragment -o unified.frag.spv unified.frag

# Compile text shader (glyph rendering)
echo "  text.vert -> text.vert.spv"
glslc -fshader-stage=vertex -o text.vert.spv text.vert

echo "  text.frag -> text.frag.spv"
glslc -fshader-stage=fragment -o text.frag.spv text.frag

# Compile SVG shader
echo "  svg.vert -> svg.vert.spv"
glslc -fshader-stage=vertex -o svg.vert.spv svg.vert

echo "  svg.frag -> svg.frag.spv"
glslc -fshader-stage=fragment -o svg.frag.spv svg.frag

# Compile image shader
echo "  image.vert -> image.vert.spv"
glslc -fshader-stage=vertex -o image.vert.spv image.vert

echo "  image.frag -> image.frag.spv"
glslc -fshader-stage=fragment -o image.frag.spv image.frag

echo "Done! SPIR-V files generated:"
ls -la *.spv 2>/dev/null || echo "  (no .spv files found - check for errors above)"
