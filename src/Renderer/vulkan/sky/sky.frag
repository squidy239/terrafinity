#version 460 core

layout(location = 0) out vec4 out_color;
layout(location = 0) in vec2 out_uv;

// std430 layout, mirrored exactly by SkyParams in SkyRenderer.zig. All vector members are
// vec4 (Zig would round a vec3-sized field to 16 bytes; GLSL std430 vec3 is 12).
// The camera block replaces an inverse view-projection matrix: the view is a pure rotation
// about the origin, so the view ray is just a combination of the camera basis vectors.
layout(set = 0, binding = 0) readonly buffer SkyParamsBlock {
    vec4 camera_front;
    vec4 camera_side;
    vec4 camera_up;
    float tan_factor;
    float tan_half;
    vec4 sun_dir;
    vec4 sun_color;
    vec4 sun_glow_color;
    float sun_angular_radius;
    float sun_glow_power;
    float sun_intensity;
    vec4 moon_dir;
    vec4 moon_color;
    float moon_angular_radius;
    float moon_phase;
    vec4 planet_dirs[4];
    vec4 planet_colors[4];
    float planet_radii[4];
    float planet_count;
    float star_density;
    float star_seed;
    float star_brightness_min;
    float star_brightness_max;
    vec4 zenith_color;
    vec4 horizon_color;
    vec4 ground_color;
    vec4 sun_scatter;
    float transition_power;
    float exposure;
} sky;

float hash11(float p) {
    p = fract(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return fract(p);
}

float hash13(vec3 p3) {
    p3 = fract(p3 * 0.1031);
    p3 += dot(p3, p3.zyx + 31.32);
    return fract((p3.x + p3.y) * p3.z);
}

vec3 starColor(float n) {
    float t = hash11(n);
    return mix(vec3(0.55, 0.65, 1.0), vec3(1.0, 0.85, 0.6), t);
}

vec3 drawStars(vec3 dir) {
    vec3 col = vec3(0.0);
    float density = max(sky.star_density, 1e-4);
    vec3 cell = floor(dir * density);
    const float radius = 0.004;
    vec3 c = cell;
    float present = hash13(c + sky.star_seed);
    if (present < 0.90) return col;
    vec3 jitter = vec3(hash13(c * 7.31), hash13(c * 13.7), hash13(c * 3.17));
    vec3 star_dir = normalize(c + jitter);
    float ang = acos(clamp(dot(dir, star_dir), -1.0, 1.0));
    float disc = smoothstep(radius, 0.0, ang);
    float brightness = mix(sky.star_brightness_min, sky.star_brightness_max, hash13(c * 5.0));
    col += starColor(hash13(c * 9.0)) * disc * disc * brightness;
    return col;
}

vec3 drawSun(vec3 dir, vec3 sdir) {
    float cos_a = dot(dir, sdir);
    float ang = acos(clamp(cos_a, -1.0, 1.0));
    float disc = 1.0 - smoothstep(sky.sun_angular_radius * 0.9, sky.sun_angular_radius, ang);
    float glow = pow(max(cos_a, 0.0), max(sky.sun_glow_power, 1.0));
    float above_horizon = smoothstep(-0.01, 0.02, sdir.y);
    return (sky.sun_color.xyz * disc + sky.sun_glow_color.xyz * glow) * sky.sun_intensity * above_horizon;
}

vec3 drawMoon(vec3 dir, vec3 sdir) {
    vec3 mdir = normalize(sky.moon_dir.xyz);
    float ang = acos(clamp(dot(dir, mdir), -1.0, 1.0));
    float disc = 1.0 - smoothstep(sky.moon_angular_radius * 0.9, sky.moon_angular_radius, ang);

    // Lit fraction: 1 = full moon (sun opposite the moon), 0 = new moon (sun behind it).
    float phase = clamp(-dot(mdir, sdir) * 0.5 + 0.5, 0.0, 1.0);
    vec3 to_sun = sdir - mdir * dot(sdir, mdir);
    vec3 sun_side = to_sun / max(length(to_sun), 1e-6);
    vec3 disc_offset = dir - mdir * dot(dir, mdir);
    float facing = length(disc_offset) > 1e-6 ? dot(disc_offset / length(disc_offset), sun_side) : 0.0;
    float lit = clamp(facing + (2.0 * phase - 1.0), 0.0, 1.0);
    float above_horizon = smoothstep(-0.01, 0.02, mdir.y);
    return sky.moon_color.xyz * disc * lit * sky.moon_phase * above_horizon;
}

vec3 drawPlanets(vec3 dir, vec3 sdir) {
    vec3 col = vec3(0.0);
    int n = int(sky.planet_count);
    for (int i = 0; i < 4; i++) {
        if (i >= n) break;
        vec3 pdir = normalize(sky.planet_dirs[i].xyz);
        float ang = acos(clamp(dot(dir, pdir), -1.0, 1.0));
        float disc = 1.0 - smoothstep(sky.planet_radii[i] * 0.9, sky.planet_radii[i], ang);
        float illum = clamp(dot(pdir, sdir) * 0.5 + 0.5, 0.0, 1.0);
        float above_horizon = smoothstep(-0.01, 0.02, pdir.y);
        col += sky.planet_colors[i].xyz * disc * (0.2 + 0.8 * illum) * above_horizon;
    }
    return col;
}

vec3 gradient(vec3 dir, vec3 sdir, float day_factor) {
    float h = dir.y;
    vec3 day_col = mix(sky.horizon_color.xyz, sky.zenith_color.xyz, pow(clamp(h, 0.0, 1.0), 1.0 / max(sky.transition_power, 0.001)));
    day_col = mix(day_col, sky.ground_color.xyz, smoothstep(0.0, -0.2, h));

    float sun_elev = sdir.y;
    float twilight = 1.0 - smoothstep(0.02, 0.4, abs(sun_elev));

    vec3 night_col = mix(vec3(0.012, 0.016, 0.03), vec3(0.05, 0.08, 0.17), pow(clamp(h, 0.0, 1.0), 1.5));
    night_col = mix(night_col, vec3(0.008, 0.008, 0.012), smoothstep(0.0, -0.1, h));

    vec3 col = mix(night_col, day_col, day_factor);

    // Scatter tint hugs the horizon when the sun is low (dusk/dawn).
    float sun_horizon = pow(max(0.0, 1.0 - sun_elev), 2.0);
    float halo = pow(max(dot(dir, sdir), 0.0), 8.0);
    col += sky.sun_scatter.xyz * sun_horizon * twilight * 0.45;
    col += sky.sun_glow_color.xyz * halo * sun_horizon * twilight * 0.35;
    return col;
}

void main() {
    vec2 ndc = out_uv * 2.0 - 1.0;
    vec3 dir = normalize(sky.camera_front.xyz + sky.camera_side.xyz * (ndc.x * sky.tan_factor) - sky.camera_up.xyz * (ndc.y * sky.tan_half));

    vec3 sdir = normalize(sky.sun_dir.xyz);
    float day_factor = smoothstep(-0.1, 0.25, sdir.y);

    vec3 col = gradient(dir, sdir, day_factor);
    if (day_factor < 1.0) col += drawStars(dir) * (1.0 - day_factor);
    col += drawSun(dir, sdir);
    col += drawMoon(dir, sdir);
    col += drawPlanets(dir, sdir);

    col *= sky.exposure;
    out_color = vec4(col, 1.0);
}
