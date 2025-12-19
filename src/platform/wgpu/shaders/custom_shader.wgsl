// Custom post-processing shader for WebGPU
// Shadertoy-compatible interface for WGSL
//
// User code should implement mainImage:
//   fn mainImage(fragCoord: vec2<f32>, uniforms: ShaderUniforms, iChannel0: texture_2d<f32>, iChannel0Sampler: sampler) -> vec4<f32>

// Shadertoy-compatible uniform buffer
struct ShaderUniforms {
    // iResolution - viewport resolution (width, height, 1.0) + padding
    iResolution: vec4<f32>,
    // iTime - shader playback time in seconds
    iTime: f32,
    // iTimeDelta - render time in seconds
    iTimeDelta: f32,
    // iFrameRate - frames per second
    iFrameRate: f32,
    // iFrame - frame counter
    iFrame: i32,
    // iMouse - mouse position (xy = current, zw = click position)
    iMouse: vec4<f32>,
    // iDate - year, month, day, time in seconds
    iDate: vec4<f32>,
    // Gooey extensions
    iFocusedBounds: vec4<f32>,
    iHoveredBounds: vec4<f32>,
    iAccentColor: vec4<f32>,
    iScrollOffset: vec2<f32>,
    _pad: vec2<f32>,
}

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) texCoord: vec2<f32>,
}

@group(0) @binding(0) var<uniform> uniforms: ShaderUniforms;
@group(0) @binding(1) var iChannel0: texture_2d<f32>;
@group(0) @binding(2) var iChannel0Sampler: sampler;

// Fullscreen triangle vertex shader (more efficient than quad)
// Generates a triangle that covers the entire screen
@vertex
fn vs_main(@builtin(vertex_index) vid: u32) -> VertexOutput {
    // Generate oversized triangle that covers the viewport
    // Position: (-1,-1), (3,-1), (-1,3)
    var positions = array<vec2<f32>, 3>(
        vec2<f32>(-1.0, -1.0),
        vec2<f32>( 3.0, -1.0),
        vec2<f32>(-1.0,  3.0)
    );

    var out: VertexOutput;
    out.position = vec4<f32>(positions[vid], 0.0, 1.0);
    // Convert from clip space to UV coordinates (0,0) to (1,1)
    // Y is flipped for texture sampling
    out.texCoord = positions[vid] * 0.5 + 0.5;
    out.texCoord.y = 1.0 - out.texCoord.y;
    return out;
}

// ============================================================================
// USER SHADER CODE GOES HERE (mainImage function)
// The mainImage function should have this signature:
//
// fn mainImage(fragCoord: vec2<f32>, iResolution: vec2<f32>, iTime: f32,
//              iChannel0: texture_2d<f32>, iChannel0Sampler: sampler) -> vec4<f32>
// ============================================================================

// Default passthrough implementation - replace with user code
fn mainImage(
    fragCoord: vec2<f32>,
    iResolution: vec2<f32>,
    iTime: f32,
    iChannel0_tex: texture_2d<f32>,
    iChannel0_samp: sampler
) -> vec4<f32> {
    let uv = fragCoord / iResolution;
    return textureSample(iChannel0_tex, iChannel0_samp, uv);
}

// ============================================================================
// END USER SHADER CODE
// ============================================================================

// Fragment shader wrapper that calls user's mainImage
@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let fragCoord = in.texCoord * uniforms.iResolution.xy;
    return mainImage(
        fragCoord,
        uniforms.iResolution.xy,
        uniforms.iTime,
        iChannel0,
        iChannel0Sampler
    );
}
