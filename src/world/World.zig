const std = @import("std");

const World = struct {
    threadPool: *std.Thread.Pool,
    onChunkAddfn: ?type, //TODO
    onChunkRemovefn: ?type, //TODO

};
