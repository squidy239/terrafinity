#version 450 core
out vec4 FragColor;
in flat vec3 position;
in vec3 coordss;
in flat uint blocktype;
//uniform sampler2D ourTexture;
//in vec2 TexCoord;
void main()
{           
    float cdfs = sqrt(pow(coordss.x,2)+pow(coordss.y,2)+pow(coordss.z,2));
    FragColor = vec4(cdfs,position.y/5,-position.y-5,1);
    
}                  