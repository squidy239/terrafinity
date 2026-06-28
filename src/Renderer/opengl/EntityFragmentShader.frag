#version 410 core
out vec4 frag_color;

in vec3 pos;
in vec3 world_pos_relative;

float bouncingMod(float x, float n) {
    x = abs(x);
    float cycle = floor(x / n);
    float remainder = mod(x, n);
    if (mod(cycle, 2.0) == 0.0) {
        return remainder;
    } else {
        return n - remainder;
    }
}

void main()
{
    // Procedural pattern for entity visualization
    float p = bouncingMod(pos.z * 16.0 + bouncingMod(world_pos_relative.z, 5.0), 1.0);
    float q = bouncingMod(-pos.z * 64.0 + bouncingMod(world_pos_relative.y, 5.0), 1.0);
    float r = bouncingMod(pos.z * 64.0 + bouncingMod(world_pos_relative.x, 5.0), 1.0);
    frag_color = vec4(p, q, r, 1.0);
}
