const std = @import("std");

pub const PacketType = enum(u16) {
    Ping = 0,
    Pong = 1,
    Unverifyed_Login = 2,
    Login_Succeded = 3,
    Login_Failed = 4,
};

pub const Ping = struct {
    pub const max_buffer_size: usize = 257;
    referrer_len: u8,
    referrer: []const u8,
    pub fn make(p: @This(), buf: []u8) []u8 {
        std.debug.assert(p.referrer.len == p.referrer_len);
        var pos: usize = 0;
        SetData(&pos, buf, p.referrer_len);
        SetData(&pos, buf, p.referrer);
        return buf[0..pos];
    }
    pub fn load(ping: []const u8) @This() {
        const referrer_len: u8 = @min(ping.len, std.mem.bytesToValue(u8, ping[0..1]));
        return @This(){
            .referrer_len = referrer_len,
            .referrer = ping[1..],
        };
    }
};

pub const Pong = struct {
    pub const max_buffer_size: usize = 514;
    server_name_len: u8,
    server_name: []const u8,
    MOTD_len: u8,
    MOTD: []const u8,
    pub fn make(p: @This(), buf: []u8) []u8 {
        std.debug.assert(p.server_name_len == p.server_name.len);
        std.debug.assert(p.MOTD_len == p.MOTD.len);
        var pos: usize = 0;
        SetData(&pos, buf, p.server_name_len);
        SetData(&pos, buf, p.server_name);
        SetData(&pos, buf, p.MOTD_len);
        SetData(&pos, buf, p.MOTD);
        return buf[0..pos];
    }
    pub fn load(pong: []const u8) @This() {
        const server_name_len: u8 = @min(pong.len, std.mem.bytesToValue(u8, pong[0..1]));
        const MOTD_len: u8 = @min(pong.len, std.mem.bytesToValue(u8, pong[server_name_len .. server_name_len + 1]));
        return @This(){ .server_name_len = server_name_len, .server_name = pong[1..server_name_len], .MOTD_len = MOTD_len, .MOTD = pong[server_name_len + 1 .. MOTD_len] };
    }
};

pub const Unverifyed_Login = struct {
    username_len: u8,
    username: []u8,
    referrer_len: u16,
    referrer: []u8,
};

pub const Login_Succeded = struct {};

pub const Login_Failed = struct {
    message_len: u8,
    message: []u8,
};

///caller guarantees pos+sizeof data < buffer.len
pub fn SetData(pos: *usize, buffer: []u8, data: anytype) void {
    if (@TypeOf(data) == []u8 or @TypeOf(data) == []const u8) {
        // For slices, we copy the actual data
        const bytedata = std.mem.sliceAsBytes(data);
        @memcpy(buffer[pos.*..][0..data.len], bytedata);
        pos.* += bytedata.len;
    } else {
        // For all other types, use byte representation
        const bytedata = std.mem.asBytes(&data);
        @memcpy(buffer[pos.* .. pos.* + bytedata.len], bytedata);
        pos.* += bytedata.len;
    }
}
