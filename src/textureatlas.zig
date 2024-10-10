const std = @import("std");
const zstbi = @import("zstbi");

fn MakeAtlas(images:[]zstbi.Image)zstbi.Image{
    var mwidth:u32 = 0;
    var height:u32 = 0;
    zstbi.i
    for(images)|im|{if(im.width > mwidth)mwidth = im.width;height+=im.height;}
    var atlas = zstbi.Image.createEmpty(mwidth, height, num_components: u32,.{});
}