const std = @import("std");
const World = @import("root").World;
const Block = @import("root").Block;
const Chunk = @import("root").Chunk;

const Size = 8;

pub const Regiona = struct {
    encoding: Encoding,

    data: []const u8,

    pub const Encoding = enum(u8) {
        Flate = 0,
    };
};

fn lessThanFn(context: anytype, a: usize, b: usize) bool {
    return @as(u96, @bitCast(context[a])) < @as(u96, @bitCast(context[b]));
}

pub const Region = struct {
    const version: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 };
    chunksStored: std.bit_set.ArrayBitSet(u8, Size * Size * Size).initEmpty(),

    file: std.fs.File,

    const ChunkHeader = packed struct {
        memEncoding: @typeInfo(Chunk.BlockEncoding).@"union".tag_type.?,
        metdata: ?packed union {
            oneBlock: Block,
        },
    };

    const Header = packed struct {
        version: std.SemanticVersion,
        chunks: [Size][Size][Size]?ChunkHeader,
    };

    fn writeHeader(writer: *std.Io.Writer, chunks: [Size][Size][Size]?*Chunk) !void {
        var header: Header = undefined;
        header.version = version;
        const flatChunkHeader: *[Size * Size * Size]?ChunkHeader = @ptrCast(*header.chunks);
        for (chunks) |chunk| {
            var chunkHeader = undefined;
            if (chunk) |c| {
                c.lock.lockShared();
                chunkHeader = .{
                    .memEncoding = c.blocks,
                    .metdata = switch (c.blocks) {
                        .oneBlock => .{ .oneBlock = c.blocks.oneBlock },
                        else => null,
                    },
                };
                c.lock.unlockShared();
            } else {
                chunkHeader = .{
                    .memEncoding = null,
                    .metdata = null,
                };
            }
            flatChunkHeader = chunkHeader;
        }
        try writer.writeStruct(header, .little);
    }

    fn wrtieCompressedChunks(writer: *std.Io.Writer, compressOptions: std.compress.flate.Compress.Options, chunks: [Size][Size][Size]?*Chunk) !void {
        var deflate_buf: [65536]u8 = undefined;
        var deflate = try std.compress.flate.Compress.init(writer, &deflate_buf, compressOptions);
        for (chunks) |chunk| {
            if (chunk) |c| {
                switch (c.blocks) {
                    .blocks => {
                        const flatblockArray: *const [Chunk.ChunkSize * Chunk.ChunkSize * Chunk.ChunkSize]Block = @ptrCast(chunk.blocks.blocks);
                        deflate.writer.writeSliceEndian(Block, flatblockArray, .little);
                    },
                    .oneBlock => {},
                }
            }
        }
        try deflate.writer.flush();
        try deflate.end();
    }
};
