#version 460 core
#extension GL_ARB_gpu_shader_int64 : require

layout(location = 0) in uvec2 data;

uniform mat4 projview;
uniform vec3 sun_dir;
uniform float time;

out vec3 coordss;
flat out uint block_array_layer;
flat out uint side;
out vec3 fragpos;
flat out vec3 sun_dir_norm;
flat out uint block_type;
flat out float scale;
flat out vec2 face_size;

struct ChunkData {
    vec3 absolute_position;
    vec3 relative_position;
    float scale;
};

layout(std430, binding = 0) buffer chunks_buffer {
    ChunkData chunks[];
};

const uint CHUNK_SIZE = 32u;
const uint COORD_BITS = 5u;
const uint COORD_MASK = CHUNK_SIZE - 1u;

uint64_t getPackedData() {
    return packUint2x32(data);
}

uint decodeBlockType(uint64_t val) {
    return uint(val & 0xFFFFu);
}

uvec3 decodeLengths(uint64_t val) {
    return uvec3(
        uint(val >> 26u) & COORD_MASK,
        uint(val >> 21u) & COORD_MASK,
        uint(val >> 16u) & COORD_MASK
    );
}

uvec3 decodePosition(uint64_t val) {
    return uvec3(
        uint(val >> 41u) & COORD_MASK,
        uint(val >> 36u) & COORD_MASK,
        uint(val >> 31u) & COORD_MASK
    );
}

uint decodeSide(uint64_t val) {
    return uint(val >> 46u) & 0x7u;
}

const vec3 CUBE_FACES[6][4] = {
    { vec3( 0.5, -0.5,  0.5), vec3( 0.5,  0.5,  0.5), vec3( 0.5,  0.5, -0.5), vec3( 0.5, -0.5, -0.5) }, // 0: +X
    { vec3(-0.5, -0.5, -0.5), vec3(-0.5,  0.5, -0.5), vec3(-0.5,  0.5,  0.5), vec3(-0.5, -0.5,  0.5) }, // 1: -X
    { vec3(-0.5,  0.5,  0.5), vec3(-0.5,  0.5, -0.5), vec3( 0.5,  0.5, -0.5), vec3( 0.5,  0.5,  0.5) }, // 2: +Y
    { vec3(-0.5, -0.5, -0.5), vec3(-0.5, -0.5,  0.5), vec3( 0.5, -0.5,  0.5), vec3( 0.5, -0.5, -0.5) }, // 3: -Y
    { vec3(-0.5, -0.5,  0.5), vec3(-0.5,  0.5,  0.5), vec3( 0.5,  0.5,  0.5), vec3( 0.5, -0.5,  0.5) }, // 4: +Z
    { vec3(-0.5,  0.5, -0.5), vec3(-0.5, -0.5, -0.5), vec3( 0.5, -0.5, -0.5), vec3( 0.5,  0.5, -0.5) }  // 5: -Z
};

float bouncingMod(float x, float n) {
    x = abs(x);
    float cycle     = floor(x / n);
    float remainder = mod(x, n);
    return (mod(cycle, 2.0) == 0.0) ? remainder : n - remainder;
}

void main() {
    vec3 relative_position = chunks[gl_DrawID].relative_position;
    vec3 absolute_position = chunks[gl_DrawID].absolute_position;
    scale = chunks[gl_DrawID].scale;

    uint64_t val = getPackedData();
    uvec3 pos     = decodePosition(val);
    uvec3 lengths = decodeLengths(val);
    block_type     = decodeBlockType(val);
    side          = decodeSide(val);
    block_array_layer = block_type;

    vec3 coords = CUBE_FACES[side][gl_VertexID];
    coords = coords + (ceil(coords) * lengths);
    coords *= scale;
    fragpos = (vec3(pos) * scale) + coords + absolute_position;
    sun_dir_norm  = normalize(sun_dir);

    // Waves
    if (block_type == 3u) {
        float speed = 2000.0;
        float t     = 1.0 + float(mod(time, 100000000.0)) / 10000000.0;
        vec3  vp    = coords + vec3(pos) * scale + absolute_position;
        float p     = 1.0 + bouncingMod(
            vp.x * vp.y * vp.z * (vp.x / vp.y / vp.z) *
            (sin(vp.x) * sin(vp.y) * sin(vp.z)),
            400.0) / 400.0;
        coords.y -= bouncingMod(p * t * speed, 0.4);
    }

    coordss = coords;
    gl_Position = projview * vec4(coords + (vec3(pos) * scale) + relative_position, 1.0);
}
