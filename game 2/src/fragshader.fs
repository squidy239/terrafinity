#version 450 core
out vec4 FragColor;
uniform uint Atlasheight;
in flat vec3 position;
in vec3 coordss;
in flat uint blocktype;
in flat uint side;
uniform sampler2D TextureAtlas;
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
    float cdfs = sqrt(pow(coordss.x,2)+pow(coordss.y,2)+pow(coordss.z,2));
    if(blocktype == 3)
        {FragColor = vec4(cdfs,cdfs,cdfs,1);}
    else if(blocktype == 1)
                {FragColor = vec4(0,cdfs,cdfs-0.5,1);}
    else if(blocktype == 2)
                {FragColor = vec4(cdfs+0.2,cdfs-0.2,cdfs-0.5,1);}

}                  