#version 410 core

in vec3 coordss;
in vec3 fragpos;
flat in vec3 sunpos;
flat in vec3 position;
flat in uint blocktype;
flat in uint side;
flat in float sscale;
uniform vec4 skyColor;
uniform float fogDensity;
uniform sampler2D TextureAtlas;
uniform uint AtlasHeight;
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
    vec4 texColor = texture(TextureAtlas, texcoords);
    FragColor = texColor;
    float cdfs = cos(pow(coordss.x, 2) + pow(coordss.y, 2) + pow(coordss.z, 2));
    if (blocktype == 3)
    {
        if (position.y < 1000) {
            float v = abs((rand(vec2(round(coordss.x * 16) / 16 / round(coordss.y * 16) / 16, round(coordss.z * 16) / 16))));
            FragColor = vec4((cdfs - 0.0001 * sscale * abs(position.y)) - v, (cdfs + 0.0001 * sscale * abs(position.y)) - v, (cdfs + 0.0001 * sscale * abs(position.y)) - v, 1);
        }
        else {
            FragColor = vec4(0.9, 0.9, 0.9, 1.0);
        }
    }
    else if (blocktype == 4)
    {
        if (gl_FragCoord.z < 0.999999) {
            FragColor = vec4(0, ((rand(vec2((round(coordss.x * 8) / 8 + abs(position.y) + 1.0) / (round((coordss.y + 0.1) * 8) / 8) + 0.2, abs(position.x) * abs(position.z) / round(coordss.z * 16) / 16) / 16))) + 0.2, abs(((rand(vec2(round(coordss.x * 4) / 4 + abs(position.y) / round(coordss.y * 4) / 4, abs(position.x) * abs(position.z) / round(coordss.z * 4) / 4) / 16))) - 0.4), 1);
        } else FragColor = vec4(0.0, 0.7, 0.2, 1.0);
    }
    else if (blocktype == 2)
    {
        FragColor = vec4(cdfs + 0.2, cdfs - 0.2, cdfs - 0.5, 1);
    }
    else if (blocktype == 5)
    {
        float barkv = bouncingMod(bouncingMod(round(coordss.x * 8) / 8, 5) + bouncingMod(round(coordss.z * 8) / 8, 5), 1);
        FragColor = vec4(0.4 * barkv, 0.2 * barkv, 0, 1);
    }
    else if (blocktype == 6)
    {
        FragColor = vec4(cdfs - 0.3, cdfs, cdfs + 0.3, 0.8);
    }
    else if (blocktype == 11)
    {
        FragColor = vec4(cdfs + 0.8, cdfs + 0.8, cdfs + 0.8, 1);
    }
    else if (blocktype == 8)
    {
        FragColor = vec4(0, ((rand(vec2((round(coordss.x * 16) / 16 + abs(position.y)) / (round((coordss.y) * 16) / 16) + 0.2, abs(position.x) * abs(position.z) / round(coordss.z * 16) / 16) / 16))) + 0.2, 0.1, 1 - round(((rand(vec2((round(coordss.x * 16) / 16 + abs(position.y)) / (round((coordss.y) * 16) / 16) + 0.2, abs(position.x) * abs(position.z) / round(coordss.z * 16) / 16) / 16))) - 0.4));
    }

    vec3 lightColor = vec3(1.0, 1.0, 1.0);
    vec3 norm = normalize(Normal);
    vec3 lightDir = normalize(sunpos - fragpos);
    float diff = max(dot(norm, lightDir), 0.0);
    vec3 diffuse = diff * lightColor;
    vec4 result = FragColor; //vec4((0.2 + diffuse) * FragColor.xyz, FragColor[3]);
    float fogDistance = gl_FragCoord.z / gl_FragCoord.w;

    float fogAmount = fogFactorExp2(fogDistance, fogDensity); //fog density
    result = mix(result, skyColor, fogAmount);

    //  result = mix(result, vec3(0, 0.3, 0.5), pow(gl_FragCoord.z, 2048));
    //if(HeadUnderwater)result = mix(result, vec3(0, 0.3, 0.5), pow(gl_FragCoord.z, 64));
    FragColor = result;

    if (FragColor.a < 0.01) discard;
}
