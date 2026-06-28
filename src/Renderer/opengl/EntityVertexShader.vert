#version 410 core

layout(location = 0) in vec3 aPos;

uniform vec3 relative_pos;
uniform mat4 proj_view;
uniform mat4 rotation;

out vec3 pos;
out vec3 world_pos_relative;

void main()
{
    pos = aPos;
    world_pos_relative = relative_pos;
    gl_Position = proj_view * vec4(relative_pos + aPos, 1.0);
}
