#version 410 core

layout(location = 0) in vec3 aPos;
uniform vec3 RelativePos;
uniform mat4 ProjView;
uniform mat4 Rotation;
out vec3 pos;
out vec3 WorldPosRelative;

void main()
{
    pos = aPos;
    WorldPosRelative = RelativePos;
    gl_Position = ProjView * vec4(RelativePos + (aPos * vec3(1, 1, 1)), 1);
}
