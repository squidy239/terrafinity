#version 430 core
layout(location = 1) in uvec2 data;
layout(location = 0) in vec3 incoords;
uniform mat4 projview;
uniform mat4 sunrot;
uniform dvec3 playerPos;
uniform double time;
out vec3 coordss;
flat out uint blockArrayLayer;
flat out uint side;
out vec3 fragpos;
flat out vec3 sunpos;
flat out uint blocktype;
const float ChunkSize = 32.0;
layout(std140, binding = 0) uniform UBO {
    float scale;
    double creationTime;
    ivec4 chunkPos;
};

const vec3 offset[6] = vec3[6](
        vec3(0.5, 0.0, 0.0), // +X
        vec3(-0.5, 0.0, 0.0), // -X
        vec3(0.0, 0.5, 0.0), // +Y
        vec3(0.0, -0.5, 0.0), // -Y
        vec3(0.0, 0.0, 0.5), // +Z
        vec3(0.0, 0.0, -0.5) // -Z
    );
const vec3 offsetmul[6] = vec3[6](
        vec3(0, 1.0, 1.0), // +X
        vec3(0, 1.0, 1.0), // -X
        vec3(1.0, 0.0, 1.0), // +Y
        vec3(1.0, 0.0, 1.0), // -Y
        vec3(1.0, 1.0, 0), // +Z
        vec3(1.0, 1.0, -0) // -Z
    );

float bouncingMod(float x, float n) {
    // Make x positive
    x = abs(x);

    // Calculate the cycle number and remainder
    float cycle = floor(x / n);
    float remainder = mod(x, n);

    // Reflect if the cycle is odd
    if (mod(cycle, 2.0) == 0.0) {
        return remainder; // Normal case
    } else {
        return n - remainder; // Reflection case
    }
}

uvec3 DecodePosition(uvec2 encodedBlock) {
    return uvec3(
        encodedBlock[0] & uint(0x1F), // x: first 5 bits
        (encodedBlock[0] >> uint(5)) & uint(0x1F), // y: next 5 bits
        (encodedBlock[0] >> uint(10)) & uint(0x1F) // z: next 5 bits
    );
}

uint DecodeSide(uvec2 encodedBlock) {
    // rot: FaceRotation (bits 15-18)
    return (encodedBlock[0] >> uint(15)) & uint(0xF);
}

uint DecodeBlockType(uvec2 encodedBlock) {
    // BlockType is in the second 32-bit word
    // It comes after isGreedy(1), height(6), width(6) bits
    return (encodedBlock[1]) & uint(0xFFFFF); // 20-bit mask (0xFFFFF = 2^20 - 1)
}
vec3 rotateVertex(uint side, vec3 coords) {
    coords -= vec3(0.5); // center vertex

    switch (side) {
        case 1:
        // -X face (left)
        coords = vec3(0.0, coords.y, coords.x);
        break;
        case 0:
        // +X face (right)
        coords = vec3(0.0, coords.y, -coords.x - 1);
        break;
        case 3:
        // -Y face (bottom)
        coords = vec3(coords.x, 0.0, coords.y);
        break;
        case 2:
        // +Y face (top)
        coords = vec3(coords.x, 0.0, -coords.y - 1);
        break;
        case 5: // -Z face (back)
        coords = vec3(coords.x, -coords.y - 1, 0.0);
        break;
        case 4:
        break; // +Z face (front) requires no rotation
    }

    coords += vec3(0.5);
    coords *= offsetmul[side];
    coords += offset[side];

    return coords;
}


float rand(vec2 co) {
    return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453);
}

void main() {
    uvec3 pos = DecodePosition(data);
    blocktype = DecodeBlockType(data);
    side = DecodeSide(data);
    blockArrayLayer = blocktype;
    vec3 coords = rotateVertex(side, incoords);
    fragpos = vec3((pos * scale) + (coords * scale) + (chunkPos.xyz * ChunkSize * scale));
    sunpos = (sunrot * vec4(0.0, 1000000.0, 0.0, 1.0)).xyz;

    float speed = 2000.0;

    float t = 1.0 + ((float(mod(time, 100000000.0))) / 10000000);

    vec3 vertexposition = coords * scale + ((vec3(pos) * scale) + (vec3(chunkPos.xyz) * ChunkSize * scale));

    if (blocktype == 7) {
        float p = 1.0 + bouncingMod(vertexposition.x * vertexposition.y * vertexposition.z * (vertexposition.x / vertexposition.y / vertexposition.z) * (sin(vertexposition.x) * sin(vertexposition.y) * sin(vertexposition.z)), 400.0) / 400.0;
        coords.y -= bouncingMod((p * t * speed), 0.4);
    }

    coordss = coords;
    float animationMs = 2500;
    float animationSpeed = 0.25;
    float chunktime = float(time - creationTime);
    vec3 relativeChunkPos = vec3(dvec3(vec3(chunkPos.xyz) * ChunkSize * scale) - playerPos);
   // coords.y += pow((animationMs - min(chunktime, animationMs))/animationMs, 2) * animationMs * animationSpeed; //replace with pos.y for other aniamtion
    float newscale = scale;
   // newscale *= 1 - (pow((animationMs - min(chunktime, animationMs))/animationMs, 2)); //replace with pos.y for other aniamtion

    gl_Position = projview * vec4((coords * newscale) + (pos * scale) + (relativeChunkPos), 1);
}



//    float scale = mod(float(time) / 1000, 4) / max(0.000001,(((abs(pow(pow(vertexposition.x, 2.0) + pow(vertexposition.y, 2.0) + pow(vertexposition.z, 2.0),0.5))))));
