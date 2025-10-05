#version 410 core

layout(location = 0) in vec2 aPos;
uniform vec2 position;
uniform vec2 size;

void main()
{
    gl_Position = vec4((aPos * size) + position, 0.0, 1.0);
}
