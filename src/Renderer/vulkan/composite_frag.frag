#version 460 core

layout(location = 0) out vec4 outColor;

layout(location = 0) in vec2 inUV;

layout(binding = 0) uniform sampler2D s_opaque_color;
layout(binding = 1) uniform sampler2D s_accum;
layout(binding = 2) uniform sampler2D s_reveal;

void main() {
    // Read accumulated values from the offscreen render targets using texelFetch
    // This is much faster for full-screen quad passes as it avoids floating-point UV math and filtering logic
    ivec2 texel_coord = ivec2(gl_FragCoord.xy);
    vec4 accum = texelFetch(s_accum, texel_coord, 0);
    vec4 wboit_accum = texelFetch(s_reveal, texel_coord, 0);
    vec4 opaque_color = texelFetch(s_opaque_color, texel_coord, 0);

    // The accumulated alpha product (revealage) from the WBOIT pass
    float wboit_reveal = accum.a;

    // Beer-Lambert Law: Intensity = Initial * exp(-Absorption)
    // accum.rgb stores the accumulated optical depth. Clamp to 0.0 to prevent light generation (negative absorption).
    vec3 transmission = exp(-max(accum.rgb, 0.0));
    
    // 1. Calculate the background color after passing through the volumetric absorption medium
    vec3 background = opaque_color.rgb * transmission;

    // 2. Composite the WBOIT surface on top of the volumetric background
    if (wboit_reveal < 1.0) {
        // Compute the average surface color by dividing the accumulated color by the total weights
        // Using explicit float 1e-5 to prevent division by zero while preserving readability
        vec3 surface_color = wboit_accum.rgb / max(wboit_accum.a, 1e-5);
        
        // Interpolate attenuation based on wboit_reveal to avoid reflection stacking and glowing issues.
        // High revealage (close to 1.0) means we only have the front-most transparent layer, which shouldn't be attenuated.
        // Low revealage (close to 0.0) means there are deeper transparent layers behind, which should be attenuated by the water volume.
        vec3 attenuated_surface = mix(surface_color * transmission, surface_color, wboit_reveal);
        
        // Standard WBOIT resolve equation: Color = Surface * (1 - Revealage) + Background * Revealage
        outColor = vec4(attenuated_surface * (1.0 - wboit_reveal) + background * wboit_reveal, 1.0);
    } else {
        // No surface drawn; just output the background with volumetric absorption
        outColor = vec4(background, 1.0);
    }
}
