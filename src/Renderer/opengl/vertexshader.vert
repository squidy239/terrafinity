#version 460 core
#extension GL_ARB_gpu_shader_int64 : require

layout(location = 0) in uvec2 data;

uniform mat4 projview;
uniform mat4 sunrot;
uniform double time;

out vec3 coordss;
flat out uint blockArrayLayer;
flat out uint side;
out vec3 fragpos;
flat out vec3 sunpos;
flat out uint blocktype;
flat out float scale;
flat out vec2 faceSize;

struct Chunk {
    vec3 absolute_position;
    vec3 relative_position;
    float scale;
};

layout(std430, binding = 0) buffer ChunkData {
    Chunk chunks[];
};

const uint CHUNK_SIZE = 32u;
const uint COORD_BITS = 5u;
const uint COORD_MASK = CHUNK_SIZE - 1u;

uint64_t GetPackedData() {
    return packUint2x32(data);
}

uint DecodeBlockType(uint64_t val) {
    return uint(val & 0xFFFFu);
}

uvec3 DecodeLengths(uint64_t val) {
    return uvec3(
        uint(val >> 26u) & COORD_MASK,
        uint(val >> 21u) & COORD_MASK,
        uint(val >> 16u) & COORD_MASK
    );
}

uvec3 DecodePosition(uint64_t val) {
    return uvec3(
        uint(val >> 41u) & COORD_MASK,
        uint(val >> 36u) & COORD_MASK,
        uint(val >> 31u) & COORD_MASK
    );
}

uint DecodeSide(uint64_t val) {
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

    uint64_t val = GetPackedData();
    uvec3 pos     = DecodePosition(val);
    uvec3 lengths = DecodeLengths(val);
    blocktype     = DecodeBlockType(val);
    side          = DecodeSide(val);
    blockArrayLayer = blocktype;

    vec3 coords = CUBE_FACES[side][gl_VertexID];
    coords = coords + (ceil(coords) * lengths);
    coords *= scale;
    fragpos = (vec3(pos) * scale) + coords + absolute_position;
    sunpos  = (sunrot * vec4(0.0, 1000000.0, 0.0, 1.0)).xyz;

    // Waves
    if (blocktype == 3u) {
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
