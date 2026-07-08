#version 460 core

// layout(early_fragment_tests) removed to allow gl_FragDepth to affect the depth test

layout(location = 0) out vec4 outAccum;
layout(location = 1) out vec4 outReveal;

layout(location = 1) in vec3 in_coords;
layout(location = 2) in vec3 fragpos;
layout(location = 3) flat in vec3 sun_dir_norm;
layout(location = 4) flat in uint side;
layout(location = 5) flat in uint block_array_layer;
layout(binding = 1) uniform sampler2DArray texture_array;
layout(binding = 2) uniform sampler2D opaque_depth_texture;
layout(location = 6) flat in float scale;
layout(location = 7) in float view_space_depth;

struct PushConstants {
    mat4 projview;
    vec3 sun_dir;
    float time;
    int draw_over;
};

layout(push_constant) uniform PushConsts {
    PushConstants pc;
} push_consts_frag;

const vec3 face_normals[6] = vec3[](
    vec3(-1.0,  0.0,  0.0),
    vec3( 1.0,  0.0,  0.0),
    vec3( 0.0, -1.0,  0.0),
    vec3( 0.0,  1.0,  0.0),
    vec3( 0.0,  0.0, -1.0),
    vec3( 0.0,  0.0,  1.0)
);

const uvec2 texcoord_axes[6] = uvec2[](
    uvec2(1, 2),
    uvec2(1, 2),
    uvec2(0, 2),
    uvec2(0, 2),
    uvec2(0, 1),
    uvec2(0, 1)
);

// Weighted Blended Order-Independent Transparency (WBOIT) weighting function
float calculate_weight(float linear_depth, float alpha) {
    float z = linear_depth;
    float tmp = 0.03 / (0.00001 + pow(z / 200.0, 4.0));
    return alpha * clamp(tmp, 0.01, 3000.0);
}

// Specialization constant to allow Vulkan pipeline to optimize out the surface drawing branches
layout(constant_id = 0) const bool draw_surface = true;

void main()
{
    vec3 normal = face_normals[side];
    vec2 texcoords = vec2(in_coords[texcoord_axes[side][0]], in_coords[texcoord_axes[side][1]]) * 2.0;

    vec4 unlit_color = texture(texture_array, vec3((texcoords + 1.0) / 2.0, float(block_array_layer)));
    if (unlit_color.a < 0.01) discard;

    // Apply surface lighting (0.5 ambient component + directional sun component)
    vec4 color = vec4((0.5 + max(dot(normal, sun_dir_norm), 0.0)) * unlit_color.rgb, unlit_color.a);

    // 1. Calculate screen space UV coordinates
    vec2 screen_uv = gl_FragCoord.xy / vec2(textureSize(opaque_depth_texture, 0));

    // 2. Sample raw depth of the opaque background behind this fragment
    float bg_depth_raw = texture(opaque_depth_texture, screen_uv).r;

    // 3. Convert raw depth to linear distance
    float bg_depth_linear = 0.01 / max(bg_depth_raw, 1e-6);

    // 4. Clamp the volume. If the backface is behind a wall, the light stops at the wall.
    float actual_z = min(view_space_depth, bg_depth_linear);

    // 5. Calculate this fragment's absorption contribution.
    // CRITICAL: We MUST use a uniform color for the volume, independent of UV coordinates.
    // Using texelFetch on the center pixel (8, 8) guarantees identical front and back face colors.
    vec4 volume_color = texelFetch(texture_array, ivec3(8, 8, block_array_layer), 0);
    vec3 absorptionColor = max(vec3(1.0) - volume_color.rgb, vec3(0.01)); 
    float density = 1.0 * volume_color.a; // Base density on texture alpha
    vec3 opticalDepth = actual_z * absorptionColor * density;

    float wboit_reveal = 0.0;
    vec4 wboit_color = vec4(0.0);

    if (draw_surface) {
        float weight = calculate_weight(view_space_depth, color.a);
        wboit_color = vec4(color.rgb * color.a, color.a) * weight;
        wboit_reveal = color.a;
    }

    // 6. The Additive Trick
    if (gl_FrontFacing) {
        // Entering the volume: Subtract Volumetric, Output Surface Alpha
        outAccum = vec4(-opticalDepth, wboit_reveal);
    } else {
        // Exiting the volume: Add Volumetric, Output Surface Alpha
        outAccum = vec4(opticalDepth, wboit_reveal);
    }

    // Output WBOIT Accumulated Color + Alpha
    outReveal = wboit_color;

    // Add a small depth bias to push transparent fragments slightly closer to the camera (Reversed-Z).
    // This prevents Z-fighting and jagged culling artifacts against coplanar opaque geometry.
    float biased_z = min(gl_FragCoord.z + 1e-5, 1.0);
    gl_FragDepth = biased_z / (push_consts_frag.pc.draw_over != 0 ? pow(max(1.0, scale), 8.0) : 1.0);
}
