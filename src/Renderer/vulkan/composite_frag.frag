#version 460 core

layout(location = 0) out vec4 out_color;

layout(binding = 0) uniform sampler2D s_opaque_color;
layout(binding = 1) uniform sampler2D s_accum;
layout(binding = 2) uniform sampler2D s_reveal;
layout(binding = 3) uniform sampler2D s_volume_weight;

layout(push_constant) uniform CompParams {
    uint scatter_enabled;
} pc;

void main() {
    ivec2 texel_coord = ivec2(gl_FragCoord.xy);
    vec4 accum = texelFetch(s_accum, texel_coord, 0);
    vec4 opaque_color = texelFetch(s_opaque_color, texel_coord, 0);

    float revealage = accum.a;
    vec3 transmission = exp(-max(accum.rgb, 0.0));

    vec3 background = opaque_color.rgb * transmission;

    if (pc.scatter_enabled != 0u) {
        float td_scalar = texelFetch(s_volume_weight, texel_coord, 0).r;
        if (td_scalar > 0.0) {
            vec3 avg_volume_color = vec3(1.0) - accum.rgb / td_scalar;
            avg_volume_color = clamp(avg_volume_color, 0.01, 1.0);
            background += avg_volume_color * (vec3(1.0) - transmission);
        }
    }

    if (revealage < 1.0) {
        vec4 wboit_accum = texelFetch(s_reveal, texel_coord, 0);
        vec3 surface_color = wboit_accum.rgb / max(wboit_accum.a, 1e-10);
        out_color = vec4(surface_color * (1.0 - revealage) + background * revealage, 1.0);
    } else {
        out_color = vec4(background, 1.0);
    }
}
