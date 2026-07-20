#version 460 core
#extension GL_EXT_nonuniform_qualifier : require

layout(location = 0) out vec4 outAccum;
layout(location = 1) out vec4 outReveal;
layout(location = 2) out float outVolume;

layout(location = 1) in vec3 in_coords;
layout(location = 2) in vec3 fragpos;
layout(location = 3) flat in vec3 sun_dir_norm;
layout(location = 4) flat in uint side;
layout(location = 5) flat in uint block_array_layer;
layout(set = 0, binding = 0) uniform sampler2D textures[];
layout(set = 2, binding = 0) uniform sampler2D opaque_depth_texture;

struct MaterialGpu {
    float density;
    float fresnel_power;
    float min_opacity;
    vec3 volume_color;
};

layout(set = 3, binding = 0, std430) readonly buffer Materials {
    MaterialGpu materials[];
};

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

float calculate_weight(float linear_depth, float alpha) {
    // This curve prevents distance scaling from dropping to 0 as violently
    float z = linear_depth;
    float depth_weight = clamp(0.03 / (1e-5 + pow(z / 200.0, 4.0)), 1e-2, 3e3);
    
    // Mix alpha into the weight curve so highly transparent things at a distance 
    // don't overwhelm opaque things
    return pow(alpha, 1.2) * depth_weight + clamp(0.3 - alpha, 0.0, 1.0);
}

layout(constant_id = 0) const bool draw_surface = true;

void main()
{
    vec3 normal = face_normals[side];
    vec2 texcoords = vec2(in_coords[texcoord_axes[side][0]], in_coords[texcoord_axes[side][1]]) * 2.0;

    vec4 unlit_color = texture(textures[nonuniformEXT(block_array_layer)], (texcoords + 1.0) / 2.0);

    vec4 color = vec4((0.5 + max(dot(normal, sun_dir_norm), 0.0)) * unlit_color.rgb, unlit_color.a);

    float view_space_depth = 1.0 / gl_FragCoord.w;
    float bg_depth_raw = texelFetch(opaque_depth_texture, ivec2(gl_FragCoord.xy), 0).r;
    // 1. Get the linear background depth (using the 100000.0 fix for the sky)
    float bg_depth_linear;
    if (bg_depth_raw < 1e-7) {
        bg_depth_linear = 100000.0; 
    } else {
        bg_depth_linear = 0.01 / bg_depth_raw;
    }
    
    // 2. Calculate distance from THIS fragment to the opaque background
    float dist_to_bg = max(bg_depth_linear - view_space_depth, 0.0);
    
    // 3. The New Additive Sign Trick
    // Frontfaces ADD their distance to the background.
    // Backfaces SUBTRACT their distance to the background.
    float sign = gl_FrontFacing ? 1.0 : -1.0;
    
    MaterialGpu mat = materials[nonuniformEXT(block_array_layer)];
    vec3 absorption = max(1.0 - mat.volume_color, vec3(0.01));
    
    // 4. Calculate final signed optical depth
    float td = dist_to_bg * mat.density * sign;
    vec3 opticalDepth = td * absorption;

    float wboit_reveal = 0.0;
    vec4 wboit_color = vec4(0.0);

    if (bg_depth_linear >= view_space_depth && gl_FrontFacing && draw_surface) {
        vec3 view_dir = normalize(-fragpos);
        float NdotV = abs(dot(normal, view_dir));
        float fresnel = pow(1.0 - NdotV, mat.fresnel_power);
        float view_alpha = mix(color.a * mat.min_opacity, color.a, fresnel);

        float weight = calculate_weight(view_space_depth, view_alpha);
        wboit_color = vec4(color.rgb * view_alpha, view_alpha) * weight;
        wboit_reveal = view_alpha;
    }

    outAccum = vec4(opticalDepth, wboit_reveal);
    outReveal = wboit_color;
    outVolume = td;
}
