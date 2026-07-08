#version 460 core

layout(location = 0) out vec4 outColor;

layout(binding = 0) uniform sampler2D s_opaque_color;
layout(binding = 1) uniform sampler2D s_accum;
layout(binding = 2) uniform sampler2D s_reveal;

void main() {
    ivec2 texel_coord = ivec2(gl_FragCoord.xy);
    vec4 accum = texelFetch(s_accum, texel_coord, 0);
    vec4 opaque_color = texelFetch(s_opaque_color, texel_coord, 0);

    float wboit_reveal = accum.a;

    // Beer-Lambert absorption: exp(-optical_depth). Clamp to 0.0 prevents negative absorption.
    vec3 transmission = exp(-max(accum.rgb, 0.0));

    vec3 background = opaque_color.rgb * transmission;

    if (wboit_reveal < 1.0) {
        vec4 wboit_accum = texelFetch(s_reveal, texel_coord, 0);
        vec3 surface_color = wboit_accum.rgb / max(wboit_accum.a, 1e-5);
        // Attenuate distant surfaces more; front-most layer (high revealage) attenuates less.
        vec3 attenuated_surface = mix(surface_color * transmission, surface_color, wboit_reveal);
        outColor = vec4(attenuated_surface * (1.0 - wboit_reveal) + background * wboit_reveal, 1.0);
    } else {
        outColor = vec4(background, 1.0);
    }
}
