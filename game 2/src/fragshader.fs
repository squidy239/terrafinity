#version 450 core
out vec4 FragColor;
in vec3 position;
in flat uint blocktype;
//uniform sampler2D ourTexture;
//in vec2 TexCoord;
void main()
{   
            FragColor = vec4(0.0,1.0,0.2,1.0);

    FragColor = vec4(position/10,1);
    
} 