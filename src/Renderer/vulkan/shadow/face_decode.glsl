#ifndef FACE_DECODE_GLSL
#define FACE_DECODE_GLSL

const uint chunk_size = 32u;
const uint coord_mask = chunk_size - 1u;

uint decodeBlockType(uint64_t val) {
    return uint(val & 0xFFFFu);
}

uvec3 decodeLengths(uint64_t val) {
    return uvec3(
        uint(val >> 26u) & coord_mask,
        uint(val >> 21u) & coord_mask,
        uint(val >> 16u) & coord_mask
    );
}

uvec3 decodePosition(uint64_t val) {
    return uvec3(
        uint(val >> 41u) & coord_mask,
        uint(val >> 36u) & coord_mask,
        uint(val >> 31u) & coord_mask
    );
}

uint decodeSide(uint64_t val) {
    return uint(val >> 46u) & 0x7u;
}

// In-plane axes per side (the two axes the face spans)
const uvec2 face_axes[6] = uvec2[](
    uvec2(1, 2), uvec2(1, 2), uvec2(0, 2), uvec2(0, 2), uvec2(0, 1), uvec2(0, 1)
);

// True when the (a0,a1) basis is left-handed vs outward normal: emit a1 edge before a0 to preserve winding
// 0:+x swap, 1:-x keep, 2:+y keep, 3:-y swap, 4:+z swap, 5:-z keep
const bool face_swap[6] = bool[](
    true, false, false, true, true, false
);

// Normal offset: even sides (+X,+Y,+Z) = +0.5, odd (-X,-Y,-Z) = -0.5
const float face_sign[6] = float[](
    0.5, -0.5, 0.5, -0.5, 0.5, -0.5
);

#endif
