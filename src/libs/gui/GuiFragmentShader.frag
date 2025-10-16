#version 410 core
out vec4 FragColor;
uniform vec4 color;

uniform vec2 upper_left;  // Top-left corner (x,y)
uniform vec2 width_height;  
uniform vec4 corner_radii; 

float roundedBoxSDF(vec2 center, vec2 size, float radius) {
    return length(max(abs(center) - size + radius, 0.0)) - radius;
}


void main() {
float edgeSoftness = 1.0;
 vec2 lower_left = vec2(upper_left.x, upper_left.y - width_height.y);
 vec2 center = lower_left + width_height * 0.5;
 vec2 p = gl_FragCoord.xy - center;

 // Determine which corner the fragment is in based on position
 float radius =
     (p.x < 0.0 && p.y > 0.0) ? corner_radii[0] :   // top-left
     (p.x >= 0.0 && p.y > 0.0) ? corner_radii[1] :  // top-right
     (p.x >= 0.0 && p.y <= 0.0) ? corner_radii[2] : // bottom-right
        corner_radii[3];  // bottom-left

 float distance = roundedBoxSDF(p, width_height * 0.5, radius);
 float smoothedAlpha = 1.0 - smoothstep(0.0, edgeSoftness, distance);
 FragColor = vec4(color.rgb, color.a * smoothedAlpha);
}
//TODO boarders