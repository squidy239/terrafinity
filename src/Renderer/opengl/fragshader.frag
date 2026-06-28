#version 450 core

in vec3 coordss;
in vec3 fragpos;
flat in vec3 sun_dir_norm;
flat in uint side;
flat in uint block_array_layer;
uniform sampler2DArray texture_array;
out vec4 frag_color;
flat in float scale;
uniform bool draw_over;

// Normals for each face direction
const vec3 face_normals[6] = vec3[](
    vec3(-1.0,  0.0,  0.0),  // +X
    vec3( 1.0,  0.0,  0.0),  // -X
    vec3( 0.0, -1.0,  0.0),  // +Y
    vec3( 0.0,  1.0,  0.0),  // -Y
    vec3( 0.0,  0.0, -1.0),  // +Z
    vec3( 0.0,  0.0,  1.0)   // -Z
);

// texcoord axes for each face: which two components of coordss to use
const uvec2 texcoord_axes[6] = uvec2[](
    uvec2(1, 2),  // +X: yz
    uvec2(1, 2),  // -X: yz
    uvec2(0, 2),  // +Y: xz
    uvec2(0, 2),  // -Y: xz
    uvec2(0, 1),  // +Z: xy
    uvec2(0, 1)   // -Z: xy
);

void main()
{
    uint s = side;
    vec3 normal = face_normals[s];

    // Build texcoords from the appropriate axes
    vec2 texcoords = vec2(coordss[texcoord_axes[s][0]], coordss[texcoord_axes[s][1]]);
    texcoords *= 2.0;

    // Diffuse lighting
    vec3 norm = normalize(normal);
    vec3 light_dir = sun_dir_norm;
    float diff = max(dot(norm, light_dir), 0.0);
    vec3 diffuse = diff * vec3(1.0);

    frag_color = texture(texture_array, vec3(((texcoords.xy) + 1.0) / 2.0, float(block_array_layer)));
    frag_color = vec4((0.5 + diffuse) * frag_color.xyz, frag_color.a);
    if (frag_color.a < 0.01) discard;

    // gl_FragDepth requires both branches in GLSL to avoid undefined value
    if (draw_over) {
        gl_FragDepth = gl_FragCoord.z / pow(max(1.0, scale), 8.0);
    } else {
        gl_FragDepth = gl_FragCoord.z;
    }
}
