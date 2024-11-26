#version 450 core
layout (location = 1) in uvec2 data;
layout (location = 0) in vec3 incoords;
uniform mat4 view;
uniform mat4 projection;
uniform ivec3 chunkpos;
uniform uint AtlasHeight;
uniform int chunktime;
out uint Atlasheight;
out vec3 coordss;
out uint side;
out vec3 position;
out uint blocktype;

uvec3 DecodePosition(uvec2 encodedBlock) {
    return uvec3(
        (encodedBlock[0] >> (32-5)) & 0x1F,
        (encodedBlock[0] >> 32-10) & 0x1F,
        (encodedBlock[0] >> 32-15) & 0x1F
        
    );
}

uint DecodeSide(uvec2 encodedBlock) {
    return (encodedBlock[0] >> 14) & 0x7;
}

uint DecodeBlockType(uvec2 encodedBlock) {
    return (encodedBlock[1] >> 12) & 0xFFFFF;
}
vec3 rotateVertex(uint side, vec3 coords) {
    // Center the vertex at the origin for easier rotation
    coords -= vec3(0.5);

    // Rotate based on the cube face (side)
    if (side == 0) {            // -X face (left)
        coords = vec3(0.0, coords.y, coords.x);
    } 
    else if (side == 1) {       // +X face (right)
        coords = vec3(0.0, coords.y, coords.x);
    }
    else if (side == 2) {       // -Y face (bottom)
        coords = vec3(coords.x, 0.0, coords.y);
    }
    else if (side == 3) {       // +Y face (top)
        coords = vec3(coords.x, 0.0, coords.y);
    }
    else if (side == 4) {       // -Z face (back)
        coords = vec3(coords.x, coords.y, 0.0);
    }
    // +Z face (front) requires no rotation.
    
    // Translate back to the correct cube face position
    coords += vec3(0.5);

    // Offset to position each face at the correct distance from the origin
    if (side == 0) coords.x = -0.5;        // -X face
    else if (side == 1) coords.x = 0.5;    // +X face
    else if (side == 2) {coords.y = -0.5;}   // -Y face
    //else if (side == 3) {coords.y = 0.5;}    // +Y face
    else if (side == 4) coords.z = -0.5;   // -Z face
    else if (side == 5) coords.z = 0.5;    // +Z face

    return coords;
}

void main(){
    vec3 pos = DecodePosition(data);
    position = chunkpos;
    Atlasheight = AtlasHeight;
    blocktype = DecodeBlockType(data);
    side = DecodeSide(data);
    vec3 coords = rotateVertex(side, incoords);
    pos.y -= (4000 - chunktime)/8;
    coordss = coords;
    gl_Position = projection * view * vec4(pos+coords+(chunkpos*32), 1.0);
    
 
}