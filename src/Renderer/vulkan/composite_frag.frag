#version 460 core

layout(location = 0) out vec4 outColor;

layout(location = 0) in vec2 inUV;

layout(binding = 0) uniform sampler2D s_opaque_color;
layout(binding = 1) uniform sampler2D s_accum;
layout(binding = 2) uniform sampler2D s_reveal;

void main() {
    // Read accumulated values from the offscreen render targets
    vec4 accum = texture(s_accum, inUV);
    vec4 wboit_accum = texture(s_reveal, inUV);
    vec4 opaque_color = texture(s_opaque_color, inUV);

    // The accumulated alpha product (revealage) from the WBOIT pass
    float wboit_reveal = accum.a;

    // Beer-Lambert Law: Intensity = Initial * exp(-Absorption)
    // accum.rgb stores the accumulated optical depth. Clamp to 0.0 to prevent light generation (negative absorption).
    // Using scalar 0.0 for promotion instead of vec3(0.0).
    vec3 transmission = exp(-max(accum.rgb, 0.0));
    
    // 1. Calculate the background color after passing through the volumetric absorption medium
    vec3 background = opaque_color.rgb * transmission;

    // 2. Composite the WBOIT surface on top of the volumetric background
    vec3 surface_color = vec3(0.0);
    if (wboit_reveal < 1.0) {
        // Compute the average surface color by dividing the accumulated color by the total weights
        // Using explicit float 0.00001 to prevent division by zero while preserving readability
        surface_color = wboit_accum.rgb / max(wboit_accum.a, 0.00001);
        
        // Standard WBOIT resolve equation: Color = Surface * (1 - Revealage) + Background * Revealage
        outColor = vec4(surface_color * (1.0 - wboit_reveal) + background * wboit_reveal, 1.0);
    } else {
        // No surface drawn; just output the background with volumetric absorption
        outColor = vec4(background, 1.0);
    }
}
