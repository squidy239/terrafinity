#version 410 core
layout(location = 1) in uvec2 data;
layout(location = 0) in vec3 incoords;
uniform mat4 projview;
uniform float scale;
uniform mat4 sunrot;
uniform vec3 relativechunkpos;
uniform ivec3 chunkpos;
uniform int chunktime;
out vec3 blockpos;
out vec3 coordss;
flat out uint side;
out vec3 fragpos;
flat out vec3 sunpos;
flat out float sscale;
flat out vec3 position;
flat out uint blocktype;

uvec3 DecodePosition(uvec2 encodedBlock) {
    return uvec3(
        (encodedBlock[0] >> uint(32 - 5)) & uint(0x1F),
        (encodedBlock[0] >> uint(32 - 10)) & uint(0x1F),
        (encodedBlock[0] >> uint(32 - 15)) & uint(0x1F)

    );
}

uint DecodeSide(uvec2 encodedBlock) {
    return (encodedBlock[0] >> uint(14)) & uint(0x7);
}

uint DecodeBlockType(uvec2 encodedBlock) {
    return (encodedBlock[1] >> uint(12)) & uint(0xFFFFF);
}
vec3 rotateVertex(uint side, vec3 coords) {
    // Center the vertex at the origin for easier rotation
    coords -= vec3(0.5);

    // Rotate based on the cube face (side)
    switch (side) {
        case 0:
            // -X face (left)
            coords = vec3(0.0, coords.y, coords.x);
            break;
        case 1:
            // +X face (right)
            coords = vec3(0.0, coords.y, -coords.x - 1);
            break;
        case 2:
            // -Y face (bottom)
            coords = vec3(coords.x, 0.0, coords.y);
            break;
        case 3:
            // +Y face (top)
            coords = vec3(coords.x, 0.0, -coords.y - 1);
            break;
        case 4: // -Z face (back)
            coords = vec3(coords.x, -coords.y - 1, 0.0);
            break;
        case 5:
            break; // +Z face (front) requires no rotation
    }

    // Translate back to the correct cube face position
    coords += vec3(0.5);

    // Offset to position each face at the correct distance from the origin
    switch (side) {
        case 0:
            coords.x = -0.5; // -X face
            break;
        case 1:
            coords.x = 0.5;  // +X face
            break;
        case 2:
            coords.y = -0.5; // -Y face
            break;
        case 3:
            coords.y = 0.5;  // +Y face
            break;
        case 4:
            coords.z = -0.5; // -Z face
            break;
        case 5:
            coords.z = 0.5;  // +Z face
            break;
    }

    return coords;
}

float rand(vec2 co) {
    return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453);
}

void main() {
    uvec3 pos = DecodePosition(data);
    sscale = scale;
    position = ((chunkpos*32 )+ivec3(pos) )*scale;
    blocktype = DecodeBlockType(data);
    side = DecodeSide(data);
    vec3 coords = rotateVertex(side, incoords);
    pos.y -= (1000 - chunktime) / 10;
    if (pos.y < 1000)
        coordss = coords;
    fragpos = vec3((pos*scale) + (coords*scale) + (chunkpos*32*scale));
    sunpos = (sunrot * vec4(0.0, 1000000.0, 0.0,1.0)).xyz;

    gl_Position = projview * vec4((coords*scale + ((pos*scale) + (relativechunkpos))),1);
    
}
