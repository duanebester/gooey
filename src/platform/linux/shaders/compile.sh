#!/bin/bash
# Compile GLSL shaders to SPIR-V for Vulkan
# Requires glslc (from Vulkan SDK or shaderc package)

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

# Compile unified shader
echo "  unified.vert -> unified.vert.spv"
glslc -fshader-stage=vertex -o unified.vert.spv unified.vert

echo "  unified.frag -> unified.frag.spv"
glslc -fshader-stage=fragment -o unified.frag.spv unified.frag

# Compile text shader
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
