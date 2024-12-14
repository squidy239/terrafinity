#version 450 core
out vec4 FragColor;
uniform uint Atlasheight;
in flat vec3 position;
in vec3 coordss;
in flat uint blocktype;
in flat uint side;
in vec3 fragpos;
in  vec3 sunpos;
uniform sampler2D TextureAtlas;

float rand(vec2 co){
    return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453);
}

void main()
{   
    vec2 texcoords = vec2(0,0);
    vec3 Normal;
    if(side == 0){
        texcoords = coordss.yz;
                            Normal = vec3(-1.0,  0.0, 0.0);


    }
    else if (side == 1){
        texcoords = coordss.yz;
                        Normal = vec3(1.0,  0.0, 0.0);



    }
    //-------------------------------------------
    else if (side == 2){
                texcoords = coordss.xz;
            Normal = vec3(0.0,  -1.0, 0.0);

    }
    else if (side == 3){
                texcoords = coordss.xz;
            Normal = vec3(0.0,  1.0, 0.0);

    }
    //-------------------------------
    else if (side == 4){
                texcoords = coordss.xy;
                            Normal = vec3(0.0,  0.0, -1.0);

    }
    else if (side == 5){
                texcoords = coordss.xy;
                Normal = vec3(0.0,  0.0, 1.0);


    }
    texcoords = texcoords * 2;
    vec4 texColor = texture(TextureAtlas, texcoords);
    FragColor = texColor;
    float cdfs = cos(pow(coordss.x,2)+pow(coordss.y,2)+pow(coordss.z,2));
    //cdfs = gl_FragCoord.z;
     //if(cdfs > 0.7) discard;
    //if(texcoords.x > 1 || texcoords.x < -1 || texcoords.y > 1 || texcoords.y < -1  )discard;
    if(blocktype == 3)
        {float v = abs((rand(vec2(round(coordss.x*16)/16/round(coordss.y*16)/16,round(coordss.z*16)/16))));
        FragColor = vec4((cdfs-0.0001*position.y)-v,(cdfs+0.0001*position.y)-v,(cdfs+0.0001*position.y)-v,1);}
    else if(blocktype == 1)
                {FragColor = vec4(0,((rand(vec2((round(coordss.x*8)/8+position.y+0.1)/(round((coordss.y+0.1)*8)/8)+0.2,position.x*position.z/round(coordss.z*16)/16)/16)))+0.2,((rand(vec2(round(coordss.x*4)/4+position.y/round(coordss.y*4)/4,position.x*position.z/round(coordss.z*4)/4)/16)))-0.4,1);}
    else if(blocktype == 2)
                {FragColor = vec4(cdfs+0.2,cdfs-0.2,cdfs-0.5,1);}
    else if(blocktype == 5)
                {FragColor = vec4(cdfs+0.4,cdfs-0.2,cdfs-0.5,1);}
    else if(blocktype == 4)
                {if(rand(vec2(round(coordss.x*4)/4+position.y/round(coordss.y*4)/4,position.x*position.z/round(coordss.z*4)/4)/16) > 0.5)discard;
                    FragColor = vec4(0,((rand(vec2((round(coordss.x*8)/16+position.y+0.1)/(round((coordss.y+0.1)*8)/8)+0.2,position.x*position.z/round(coordss.z*16)/16)/16)))+0.2,((rand(vec2(round(coordss.x*4)/4+position.y/round(coordss.y*4)/4,position.x*position.z/round(coordss.z*4)/4)/16)))-0.4,1);}

    
    vec3 lightColor = vec3(1.0,1.0,1.0);
    vec3 norm = normalize(Normal);
    vec3 lightDir = normalize(sunpos - fragpos); 
    float diff = max(dot(norm, lightDir), 0.0);
    vec3 diffuse = diff * lightColor;
    vec3 result = (0.2 + diffuse) * FragColor.xyz;
    result = mix(result,vec3(0, 0.3, 0.5),pow(gl_FragCoord.z,1024));
    FragColor = vec4(result, 1.0);
}                  