#version 410 core
layout(location = 0) in vec2 vertex;
out vec2 TexCoords;

const vec2 textureIndecies[6] = vec2[6](
    vec2(0.0, 0.0),
    vec2(0.0, 1.0),
    vec2(1.0, 1.0),
    vec2(0.0, 0.0),
    vec2(1.0, 1.0),
    vec2(1.0, 0.0)
);

void main()
{
    gl_Position = vec4(vertex.xy, 0.0, 1.0);
    TexCoords = textureIndecies[gl_VertexID % 6];
}
