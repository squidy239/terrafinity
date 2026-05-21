#version 460 core
layout(location = 1) in uvec2 data;
layout(location = 0) in vec3 incoords;
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

struct Chunk {
    vec3 absolute_position;
    vec3 relative_position;
    float scale;
};
layout(std430, binding = 0) buffer ChunkData {
    Chunk chunks[];
};

const uint CHUNK_SIZE   = 32;
const uint COORD_BITS   = uint(log2(float(CHUNK_SIZE)));

const uint COORD_MASK    = CHUNK_SIZE - 1u;           // e.g. 0x1F
const uint ROT_OFFSET    = COORD_BITS * 3u;           // 15
const uint BLOCK_OFFSET  = ROT_OFFSET + 4u;           // 19  (crosses u32 word boundary)
const uint BITS_IN_WORD0 = 32u - BLOCK_OFFSET;        // 13  bits of BlockType in data[0]
const uint BITS_IN_WORD1 = 16u - BITS_IN_WORD0;       //  3  bits of BlockType in data[1]

uvec3 DecodePosition(uvec2 d) {
    return uvec3(
         d[0]                     & COORD_MASK,
        (d[0] >> COORD_BITS)      & COORD_MASK,
        (d[0] >> (COORD_BITS*2u)) & COORD_MASK
    );
}

uint DecodeSide(uvec2 d) {
    return (d[0] >> ROT_OFFSET) & 0xFu;
}

uint DecodeBlockType(uvec2 d) {
    uint low  =  d[0] >> BLOCK_OFFSET;
    uint high = (d[1] & ((1u << BITS_IN_WORD1) - 1u)) << BITS_IN_WORD0;
    return low | high;
}

// ── Geometry helpers ────────────────────────────────────────────────────────
const vec3 offset[6] = vec3[6](
    vec3( 0.5, 0.0, 0.0),   // +X
    vec3(-0.5, 0.0, 0.0),   // -X
    vec3( 0.0, 0.5, 0.0),   // +Y
    vec3( 0.0,-0.5, 0.0),   // -Y
    vec3( 0.0, 0.0, 0.5),   // +Z
    vec3( 0.0, 0.0,-0.5)    // -Z
);
const vec3 offsetmul[6] = vec3[6](
    vec3(0.0, 1.0, 1.0),    // +X
    vec3(0.0, 1.0, 1.0),    // -X
    vec3(1.0, 0.0, 1.0),    // +Y
    vec3(1.0, 0.0, 1.0),    // -Y
    vec3(1.0, 1.0, 0.0),    // +Z
    vec3(1.0, 1.0, 0.0)     // -Z
);

float bouncingMod(float x, float n) {
    x = abs(x);
    float cycle     = floor(x / n);
    float remainder = mod(x, n);
    return (mod(cycle, 2.0) == 0.0) ? remainder : n - remainder;
}

vec3 rotateVertex(uint s, vec3 coords) {
    coords -= vec3(0.5);
    switch (s) {
        case 1: coords = vec3(0.0,  coords.y,          coords.x      ); break; // -X
        case 0: coords = vec3(0.0,  coords.y,         -coords.x - 1.0); break; // +X
        case 3: coords = vec3(coords.x, 0.0,           coords.y      ); break; // -Y
        case 2: coords = vec3(coords.x, 0.0,          -coords.y - 1.0); break; // +Y
        case 5: coords = vec3(coords.x, -coords.y - 1.0, 0.0         ); break; // -Z
        case 4: break;                                                          // +Z
    }
    coords += vec3(0.5);
    coords *= offsetmul[s];
    coords += offset[s];
    return coords;
}

void main() {
    vec3 relative_position = chunks[gl_DrawID].relative_position;
    vec3 absolute_position = chunks[gl_DrawID].absolute_position;
    scale = chunks[gl_DrawID].scale;

    uvec3 pos  = DecodePosition(data);
    blocktype  = DecodeBlockType(data);
    side       = DecodeSide(data);
    blockArrayLayer = blocktype;

    vec3 coords = rotateVertex(side, incoords);
    fragpos = (vec3(pos) * scale) + (coords * scale) + absolute_position;
    sunpos  = (sunrot * vec4(0.0, 1000000.0, 0.0, 1.0)).xyz;

    if (blocktype == 7u) { // water
        float speed = 2000.0;
        float t     = 1.0 + float(mod(time, 100000000.0)) / 10000000.0;
        vec3  vp    = coords * scale + vec3(pos) * scale + absolute_position;
        float p     = 1.0 + bouncingMod(
            vp.x * vp.y * vp.z * (vp.x / vp.y / vp.z) *
            (sin(vp.x) * sin(vp.y) * sin(vp.z)),
            400.0) / 400.0;
        coords.y -= bouncingMod(p * t * speed, 0.4);
    }

    coordss     = coords;
    gl_Position = projview * vec4((coords * scale) + (vec3(pos) * scale) + relative_position, 1.0);
}