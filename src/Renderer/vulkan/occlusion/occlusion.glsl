// Hi-Z occlusion test shared by GPU culling shaders. The consumer's pipeline layout
// must include DepthPyramid's occlusion set (sampled pyramid + per-frame params) at
// OCCLUSION_SET, pushed each dispatch via DepthPyramid.pushOcclusionSet.

#ifndef OCCLUSION_SET
#define OCCLUSION_SET 1
#endif

layout(set = OCCLUSION_SET, binding = 0) uniform sampler2D hiz_pyramid;

layout(std430, set = OCCLUSION_SET, binding = 1) readonly buffer HizParamsBuffer {
    mat4 projview;
    // Camera position the pyramid's depth was rendered with, so boxes can be
    // expressed in that view's camera-relative space.
    vec4 occlusion_player_pos;
    vec2 pyramid_size;
    uint mip_count;
    uint enabled;
} hiz;

// True when the camera-relative AABB is provably hidden behind the depth pyramid:
// with reversed-Z the box's nearest depth must be farther (smaller) than every
// occluder covering its screen footprint. Conservative, so any doubt (near-plane
// crossing, offscreen corners) returns false (visible).
bool hizOccluded(vec3 aabb_min, vec3 aabb_max) {
    vec2 uv_min = vec2(1.0);
    vec2 uv_max = vec2(0.0);
    float nearest_depth = 0.0;
    for (int i = 0; i < 8; i++) {
        vec3 corner = mix(aabb_min, aabb_max, vec3(i & 1, (i >> 1) & 1, (i >> 2) & 1));
        vec4 clip = hiz.projview * vec4(corner, 1.0);
        // A corner at or behind the eye plane makes the projected bounds unusable.
        if (clip.w <= 0.0) return false;
        vec3 ndc = clip.xyz / clip.w;
        vec2 uv = ndc.xy * 0.5 + 0.5;
        uv_min = min(uv_min, uv);
        uv_max = max(uv_max, uv);
        nearest_depth = max(nearest_depth, ndc.z);
    }
    // Closer than the near plane: trivially visible.
    if (nearest_depth >= 1.0) return false;

    // Footprint entirely outside the previous frame's viewport: the screen-edge depths
    // do not bound it, so treat the box as visible rather than clamping into edge texels.
    if (uv_max.x < 0.0 || uv_min.x > 1.0 || uv_max.y < 0.0 || uv_min.y > 1.0) return false;

    uv_min = clamp(uv_min, vec2(0.0), vec2(1.0));
    uv_max = clamp(uv_max, vec2(0.0), vec2(1.0));

    // Pick the mip where the footprint spans at most 2x2 texels, then min those taps.
    vec2 rect_texels = (uv_max - uv_min) * hiz.pyramid_size;
    float level = ceil(log2(max(max(rect_texels.x, rect_texels.y), 1.0)));
    level = min(level, float(hiz.mip_count - 1u));

    ivec2 mip_size = max(ivec2(hiz.pyramid_size) >> int(level), ivec2(1));
    // The mip chain's odd reductions give the last texel of each level extra source
    // rows, so texels do not span uv space uniformly. Map through the uniform mip-0
    // grid instead: texel k covers mip-0 rows [k << level, (k+1) << level), with the
    // last texel absorbing the remainder (handled by the clamp).
    ivec2 texel_min = clamp(ivec2(uv_min * hiz.pyramid_size) >> int(level), ivec2(0), mip_size - 1);
    ivec2 texel_max = clamp(ivec2(uv_max * hiz.pyramid_size) >> int(level), ivec2(0), mip_size - 1);

    float farthest = texelFetch(hiz_pyramid, texel_min, int(level)).r;
    farthest = min(farthest, texelFetch(hiz_pyramid, ivec2(texel_max.x, texel_min.y), int(level)).r);
    farthest = min(farthest, texelFetch(hiz_pyramid, ivec2(texel_min.x, texel_max.y), int(level)).r);
    farthest = min(farthest, texelFetch(hiz_pyramid, texel_max, int(level)).r);

    return nearest_depth < farthest;
}
