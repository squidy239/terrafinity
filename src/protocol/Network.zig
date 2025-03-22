const std = @import("std");
const Requests = @import("Requests");
const zudp = @import("zudp");
const SetData = @import("Requests").SetData;
const PacketType = @import("Requests").PacketType;

pub const Options = struct {
    verify: bool,
    datasplitsize: u16,
    rate_limit_bytes_second: ?f64,
    compress_sizel1: u32,
    compress_sizel2: u32,
    compress_sizel3: u32,
};

pub const Compression = enum(u8) {
    None = 0,
    zlib_4 = 1,
    zlib_6 = 2,
    zlib_9 = 3,
};

pub fn SendPacket(packet_type: PacketType, data: []const u8, comptime options: Options, max_data_size: comptime_int, conn: *zudp.Connection, destenation_address: std.posix.sockaddr) !void {
    const header_size = @sizeOf(PacketType) + @sizeOf(Compression);
    var pktbuffer: [max_data_size + header_size]u8 = undefined;
    var pos: usize = 0;
    const compression_type: Compression = switch (data.len + header_size) {
        0...options.compress_sizel1 => Compression.None,
        options.compress_sizel1 + 1...options.compress_sizel2 => Compression.zlib_4,
        options.compress_sizel2 + 1...options.compress_sizel3 => Compression.zlib_6,
        options.compress_sizel3 + 1...std.math.maxInt(usize) => Compression.zlib_9,
    };
    SetData(&pos, &pktbuffer, packet_type);
    SetData(&pos, &pktbuffer, compression_type);
    var buffstream = std.io.fixedBufferStream(pktbuffer[header_size..]);
    const writer = buffstream.writer();
    var rstream = std.io.fixedBufferStream(data);
    const reader = rstream.reader();
    switch (compression_type) {
        .None => {
            @memcpy(pktbuffer[header_size .. data.len + header_size], data);
            pos += data.len;
        },
        .zlib_4 => {
            try std.compress.zlib.compress(reader, writer, .{ .level = .level_4 });
            pos += writer.context.pos;
        },
        .zlib_6 => {
            try std.compress.zlib.compress(reader, writer, .{ .level = .level_6 });
            pos += writer.context.pos;
        },
        .zlib_9 => {
            try std.compress.zlib.compress(reader, writer, .{ .level = .level_9 });
            pos += writer.context.pos;
        },
    }
    const final_packet = pktbuffer[0..pos];
    //  std.debug.print("ct: {any}, finalpkt: {any}", .{ compression_type, final_packet });
    try conn.send(destenation_address, final_packet, options.verify, options.datasplitsize, options.rate_limit_bytes_second);
}

pub fn LoadPacket(packet: []const u8, buffer_to_put: []u8) !decompressedpkt {
    var end_pos: usize = 0;
    const header_size = @sizeOf(PacketType) + @sizeOf(Compression);
    const packet_type: PacketType = std.mem.bytesToValue(PacketType, packet[0..2]);
    const compression_type: Compression = std.mem.bytesToValue(Compression, packet[2..3]);
    // std.debug.print("pkt: {any}\n", .{packet});
    var buffstream = std.io.fixedBufferStream(buffer_to_put);
    const writer = buffstream.writer();
    var rstream = std.io.fixedBufferStream(packet[header_size..]);
    const reader = rstream.reader();
    switch (compression_type) {
        .None => {
            @memcpy(buffer_to_put[0 .. packet.len - header_size], packet[header_size..packet.len]);
            end_pos += packet.len - header_size;
        },
        .zlib_4 => {
            try std.compress.zlib.decompress(reader, writer);
            end_pos += writer.context.pos;
        },
        .zlib_6 => {
            try std.compress.zlib.decompress(reader, writer);
            end_pos += writer.context.pos;
        },
        .zlib_9 => {
            try std.compress.zlib.decompress(reader, writer);
            end_pos += writer.context.pos;
        },
    }
    return decompressedpkt{ .pktType = packet_type, .data = buffer_to_put[0..end_pos] };
}

const decompressedpkt = struct { pktType: PacketType, data: []u8 };

pub fn main() !void {
    const a = std.heap.smp_allocator;
    var conn = try zudp.Connection.init("0.0.0.0", 22522, a);
    defer conn.deinit();
    const empt: [255]u8 = @splat('a');
    var buf: [Requests.Ping.max_buffer_size]u8 = undefined;
    const req = Requests.Ping.make(.{ .referrer = &empt, .referrer_len = empt.len }, &buf);
    try SendPacket(
        .Ping,
        req,
        .{
            .verify = true,
            .compress_sizel1 = 128,
            .compress_sizel2 = 511,
            .compress_sizel3 = 2047,
            .datasplitsize = 512,
            .rate_limit_bytes_second = null,
        },
        Requests.Ping.max_buffer_size,
        &conn,
        (try std.net.Address.parseIp("127.0.0.1", 4335)).any,
    );
}
