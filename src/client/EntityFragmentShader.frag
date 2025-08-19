#version 410 core
out vec4 FragColor;

in vec3 pos;
in vec3 WorldPosRelative;

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
    FragColor = vec4(((bouncingMod(pos[2] * 16 + bouncingMod(WorldPosRelative[2], 5), 1))), (bouncingMod(-pos[2] * 64 + bouncingMod(WorldPosRelative[1], 5), 1)), (bouncingMod(pos[2] * 64 + bouncingMod(WorldPosRelative[0], 5), 1)), 1.0); // set the output variable to a dark-red color
}
