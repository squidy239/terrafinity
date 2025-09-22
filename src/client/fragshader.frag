#version 410 core

in vec3 coordss;
in vec3 fragpos;
flat in vec3 sunpos;
flat in vec3 position;
flat in uint blocktype;
flat in uint side;
flat in float sscale;
flat in uint blockArrayLayer;
uniform vec4 skyColor;
uniform float fogDensity;
uniform sampler2DArray TextureArray;
uniform bool HeadUnderwater;
out vec4 FragColor;

float rand(vec2 co) {
    return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453);
}

float fogFactorExp2(
    const float dist,
    const float density
) {
    const float LOG2 = -1.442695;
    float d = density * dist;
    return 1.0 - clamp(exp2(d * d * LOG2), 0.0, 1.0);
}

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

void main()
{
    vec2 texcoords = vec2(0, 0);
    vec3 Normal;
    if (side == 0) {
        texcoords = coordss.yz;
        Normal = vec3(-1.0, 0.0, 0.0);
    }
    else if (side == 1) {
        texcoords = coordss.yz;
        Normal = vec3(1.0, 0.0, 0.0);
    }
    //-------------------------------------------
    else if (side == 2) {
        texcoords = coordss.xz;
        Normal = vec3(0.0, -1.0, 0.0);
    }
    else if (side == 3) {
        texcoords = coordss.xz;
        Normal = vec3(0.0, 1.0, 0.0);
    }
    //-------------------------------
    else if (side == 4) {
        texcoords = coordss.xy;
        Normal = vec3(0.0, 0.0, -1.0);
    }
    else if (side == 5) {
        texcoords = coordss.xy;
        Normal = vec3(0.0, 0.0, 1.0);
    }
    texcoords = texcoords * 2;
    vec3 lightColor = vec3(1.0, 1.0, 1.0);
    vec3 norm = normalize(Normal);
    vec3 lightDir = normalize(sunpos - fragpos);
    float diff = max(dot(norm, lightDir), 0.0);
    vec3 diffuse = diff * lightColor;

    //  result = mix(result, vec3(0, 0.3, 0.5), pow(gl_FragCoord.z, 2048));
    //if(HeadUnderwater)result = mix(result, vec3(0, 0.3, 0.5), pow(gl_FragCoord.z, 64));
    FragColor = texture(TextureArray, vec3(((texcoords.xy) + 1) / 2, blockArrayLayer));
    FragColor = vec4((0.2 + diffuse) * FragColor.xyz, FragColor[3]);
    if (FragColor.a < 0.01) discard;
}
