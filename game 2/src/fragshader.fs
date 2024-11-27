#version 450 core
out vec4 FragColor;
uniform uint Atlasheight;
in flat vec3 position;
in vec3 coordss;
in flat uint blocktype;
in flat uint side;
uniform sampler2D TextureAtlas;

float rand(vec2 co){
    return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453);
}

void main()
{   
    vec2 texcoords = vec2(0,0);
    if(side == 0){
        texcoords = coordss.yz;
    }
    else if (side == 1){
        texcoords = coordss.yz;

    }
    //-------------------------------------------
    else if (side == 2){
                texcoords = coordss.xz;

    }
    else if (side == 3){
                texcoords = coordss.xz;

    }
    //-------------------------------
    else if (side == 4){
                texcoords = coordss.xy;

    }
    else if (side == 5){
                texcoords = coordss.xy;

    }
    texcoords = texcoords * 2;
    vec4 texColor = texture(TextureAtlas, texcoords);
    FragColor = texColor;
    float cdfs = cos(pow(coordss.x,2)+pow(coordss.y,2)+pow(coordss.z,2));
    if(blocktype == 3)
        {float v = abs((rand(vec2(round(coordss.x*16)/16/round(coordss.y*16)/16,round(coordss.z*16)/16))));
        FragColor = vec4((cdfs-0.0001*position.y)-v,(cdfs+0.0001*position.y)-v,(cdfs+0.0001*position.y)-v,1);}
    else if(blocktype == 1)
                {FragColor = vec4(0,((rand(vec2((round(coordss.x*8)/8+position.y+0.1)/(round((coordss.y+0.1)*8)/8)+0.2,position.x*position.z/round(coordss.z*16)/16)/16)))+0.2,((rand(vec2(round(coordss.x*4)/4+position.y/round(coordss.y*4)/4,position.x*position.z/round(coordss.z*4)/4)/16)))-0.4,1);}
    else if(blocktype == 2)
                {FragColor = vec4(cdfs+0.2,cdfs-0.2,cdfs-0.5,1);}

}                  