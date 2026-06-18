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
flat out vec2 faceSize;   // face extents in blocks (u, v); use for texture tiling
struct Chunk {
    vec3 absolute_position;
    vec3 relative_position;
    float scale;
};
layout(std430, binding = 0) buffer ChunkData {
    Chunk chunks[];
};

const uint CHUNK_SIZE = 32u;
const uint COORD_BITS = 5u;              // log2(CHUNK_SIZE)
const uint COORD_MASK = CHUNK_SIZE - 1u; // 0x1F

uint DecodeBlockType(uvec2 d) {
    return d[0] & 0xFFFFu;
}

// Returns (xlength, ylength, zlength). Add 1 for the actual block span.
uvec3 DecodeLengths(uvec2 d) {
    return uvec3(
        (d[0] >> 26u) & COORD_MASK,   // xlength: bits 26-30
        (d[0] >> 21u) & COORD_MASK,   // ylength: bits 21-25
        (d[0] >> 16u) & COORD_MASK    // zlength: bits 16-20
    );
}

// z straddles the word boundary: bit 31 of d[0] is z's LSB;
// bits 0-3 of d[1] are z's upper four bits.
uvec3 DecodePosition(uvec2 d) {
    uint z = ((d[0] >> 31u) & 1u) | ((d[1] & 0xFu) << 1u);
    uint y =  (d[1] >>  4u) & COORD_MASK;
    uint x =  (d[1] >>  9u) & COORD_MASK;
    return uvec3(x, y, z);
}

uint DecodeSide(uvec2 d) {
    return (d[1] >> 14u) & 0xFu;
}

// ── Geometry helpers ─────────────────────────────────────────────────────────
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

// Returns (u-scale, v-scale) in blocks for a given face direction.
// Matches how rotateVertex maps incoords axes onto world axes:
//   ±X : incoords.x → Z,  incoords.y → Y
//   ±Y : incoords.x → X,  incoords.y → Z
//   ±Z : incoords.x → X,  incoords.y → Y
vec2 computeFaceSize(uint s, uvec3 lengths) {
    float xl = float(lengths.x + 1u);
    float yl = float(lengths.y + 1u);
    float zl = float(lengths.z + 1u);
    switch (s) {
        case 0: case 1: return vec2(zl, yl);   // ±X
        case 2: case 3: return vec2(xl, zl);   // ±Y
        default:        return vec2(xl, yl);   // ±Z (4, 5)
    }
}

float bouncingMod(float x, float n) {
    x = abs(x);
    float cycle     = floor(x / n);
    float remainder = mod(x, n);
    return (mod(cycle, 2.0) == 0.0) ? remainder : n - remainder;
}

vec3 rotateVertex(uint s, vec3 coords) {
    coords -= vec3(0.5);
    switch (s) {
        case 1: coords = vec3(0.0,  coords.y,            coords.x      ); break; // -X
        case 0: coords = vec3(0.0,  coords.y,           -coords.x - 1.0); break; // +X
        case 3: coords = vec3(coords.x, 0.0,             coords.y      ); break; // -Y
        case 2: coords = vec3(coords.x, 0.0,            -coords.y - 1.0); break; // +Y
        case 5: coords = vec3(coords.x, -coords.y - 1.0, 0.0           ); break; // -Z
        case 4: break;                                                             // +Z
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

    uvec3 pos     = DecodePosition(data);
    uvec3 lengths = DecodeLengths(data);
    blocktype     = DecodeBlockType(data);
    side          = DecodeSide(data);
    blockArrayLayer = blocktype;

    // Expand the unit quad into face-local block units before rotating so the
    // geometry covers all (xlength+1) × (ylength+1) × (zlength+1) blocks.
    faceSize  = computeFaceSize(side, lengths);
    vec3 scaled    = vec3(incoords.xy * faceSize, incoords.z);
    vec3 coords    = rotateVertex(side, scaled);

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
