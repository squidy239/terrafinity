const std = @import("std");

const ChunkSize = 32;
const Entitys = @import("Entitys");
const Chunk = @import("Chunk");

pub const PacketType = enum(u16) {
    ServerboundPing,
    ClientboundPong,
    ServerboundLoginStart,
    ClientboundLoginData,
    ServerboundLoginComplete,
    ClientboundDisconnect,
};

pub const Version = enum(u16) {
    Testing = 0,
};

//TODO pick one endian and varint
pub const Ping = struct {
    pub const max_buffer_size: usize = 223;
    referrer_len: u8,
    referrer: []const u8,
    version: Version,
    pub fn make(p: @This(), buf: []u8) []u8 {
        std.debug.assert(p.referrer_len == p.referrer.len);
        var pos: usize = 0;
        SetData(&pos, buf, p.referrer_len);
        SetData(&pos, buf, p.referrer);
        SetData(&pos, buf, p.version);
        return buf[0..pos];
    }

    pub fn load(ping_data: []const u8) !@This() {
        var pos: usize = 0;
        const referrer_len = try GetData(&pos, ping_data, u8, null);
        const referrer = try GetData(&pos, ping_data, []const u8, referrer_len);
        const version = try std.meta.intToEnum(Version, try GetData(&pos, ping_data, u16, null));

        return @This(){
            .referrer_len = referrer_len,
            .referrer = referrer,
            .version = version,
        };
    }
};

pub const Pong = struct {
    pub const max_buffer_size: usize = 514;
    server_name_len: u8,
    server_name: []const u8,
    MOTD_len: u8,
    MOTD: []const u8,
    version: Version,
    pub fn make(p: @This(), buf: []u8) []u8 {
        std.debug.assert(p.server_name_len == p.server_name.len);
        std.debug.assert(p.MOTD_len == p.MOTD.len);
        var pos: usize = 0;
        SetData(&pos, buf, p.server_name_len);
        SetData(&pos, buf, p.server_name);
        SetData(&pos, buf, p.MOTD_len);
        SetData(&pos, buf, p.MOTD);
        SetData(&pos, buf, p.version);
        return buf[0..pos];
    }
    pub fn load(pong: []const u8) !@This() {
        var pos: usize = 0;
        const server_name_len: u8 = try GetData(&pos, pong, u8, null);
        const server_name = try GetData(&pos, pong, []const u8, server_name_len);
        const MOTD_len: u8 = try GetData(&pos, pong, u8, null);
        const MOTD = try GetData(&pos, pong, []const u8, MOTD_len);
        const version = try std.meta.intToEnum(Version, try GetData(&pos, pong, u16, null));
        return @This(){
            .server_name_len = server_name_len,
            .server_name = server_name,
            .MOTD_len = MOTD_len,
            .MOTD = MOTD,
            .version = version,
        };
    }
};

pub const LoginStart = struct { //TODO verifacation
    pub const max_buffer_size: usize = 532;
    version: Version,
    UUID: u128,
    username_len: u8,
    username: []const u8,
    referrer_len: u8,
    referrer: []const u8,

    pub fn make(p: @This(), buf: []u8) []u8 {
        std.debug.assert(p.username_len == p.username.len);
        std.debug.assert(p.referrer_len == p.referrer.len);
        var pos: usize = 0;
        SetData(&pos, buf, p.version);
        SetData(&pos, buf, p.UUID);
        SetData(&pos, buf, p.username_len);
        SetData(&pos, buf, p.username);
        SetData(&pos, buf, p.referrer_len);
        SetData(&pos, buf, p.referrer);
        return buf[0..pos];
    }

    pub fn load(login_data: []const u8) !@This() {
        var pos: usize = 0;
        const version = try std.meta.intToEnum(Version, try GetData(&pos, login_data, u16, null));
        const UUID = try GetData(&pos, login_data, u128, null);
        const username_len = try GetData(&pos, login_data, u8, null);
        const username = try GetData(&pos, login_data, []const u8, username_len);
        const referrer_len = try GetData(&pos, login_data, u8, null);
        const referrer = try GetData(&pos, login_data, []const u8, referrer_len);

        return @This(){
            .version = version,
            .UUID = UUID,
            .username_len = username_len,
            .username = username,
            .referrer_len = referrer_len,
            .referrer = referrer,
        };
    }
};

pub const LoginData = struct {
    pub const max_buffer_size: usize = 149;

    ipVerifyNumber: u64,
    pos: @Vector(3, f64),
    Velocity: @Vector(3, f64),
    GameMode: Entitys.GameMode,
    maxGenDistance: [3]u32,
    genParams: Chunk.Chunk.GenParams,

    pub fn make(p: @This(), buf: []u8) []u8 {
        var pos: usize = 0;
        SetData(&pos, buf, p.ipVerifyNumber);
        SetData(&pos, buf, p.pos);
        SetData(&pos, buf, p.Velocity);
        SetData(&pos, buf, p.GameMode);
        SetData(&pos, buf, p.maxGenDistance);
        SetData(&pos, buf, p.genParams);
        return buf[0..pos];
    }

    pub fn load(login_data: []const u8) !@This() {
        var pos: usize = 0;
        const ipVerifyNumber = try GetData(&pos, login_data, u64, null);
        const position = try GetData(&pos, login_data, @Vector(3, f64), null);
        const velocity = try GetData(&pos, login_data, @Vector(3, f64), null);
        const gameMode = try GetData(&pos, login_data, Entitys.GameMode, null);
        const maxGenDistance = try GetData(&pos, login_data, [3]u32, null);
        const genParams = try GetData(&pos, login_data, Chunk.Chunk.GenParams, null);

        return @This(){
            .ipVerifyNumber = ipVerifyNumber,
            .pos = position,
            .Velocity = velocity,
            .GameMode = gameMode,
            .maxGenDistance = maxGenDistance,
            .genParams = genParams,
        };
    }
};

pub const LoginComplete = packed struct {
    ipVerifyNumber: u64, //must be the same one client reiceved
};

pub const Disconnect = struct {
    pub const max_buffer_size: usize = 257;
    message_len: u8,
    message: []const u8,

    pub fn make(p: @This(), buf: []u8) []u8 {
        std.debug.assert(p.message_len == p.message.len);
        var pos: usize = 0;
        SetData(&pos, buf, p.message_len);
        SetData(&pos, buf, p.message);
        return buf[0..pos];
    }

    pub fn load(login_failed_data: []const u8) !@This() {
        var pos: usize = 0;
        const message_len = try GetData(&pos, login_failed_data, u8, null);
        const message = try GetData(&pos, login_failed_data, []const u8, message_len);

        return @This(){
            .message_len = message_len,
            .message = message,
        };
    }
};

//TODO beond this point
//
//
//_____________________________________________
pub const Send_Chunks = struct {
    chunk_amount: u8,
    chunks: []const len_prefixed_chunkdata,

    const len_prefixed_chunkdata = struct {
        chunk_len: u32,
        chunk_data: []const u8, //will be blockencoding
    };
};

//client sends gendistance and server sends chunks, @min(client_gendistance, server_max_gendistance)

pub const Client_Chunk_Request = struct {
    chunk_amount: u8,
    chunks: []const [3]i32,
};

pub const Client_Chunk_Request_Response = struct {
    chunk_amount: u8,
    chunks_modified: []const [3]i32, //server will send these chunks
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

///wont validate enums
pub fn GetData(pos: *usize, buffer: []const u8, comptime T: type, slicelen: ?usize) !T {
    std.debug.assert(T != Version);
    if (T == []u8 or T == []const u8) {
        if (pos.* + slicelen.? > buffer.len) return error.BufferToSmall;
        const result = buffer[pos.* .. pos.* + slicelen.?];
        pos.* += slicelen.?;
        return result;
    } else {
        const size = @sizeOf(T);
        if (pos.* + size > buffer.len) return error.BufferToSmall;
        const result = std.mem.bytesToValue(T, buffer[pos.* .. pos.* + size]);
        pos.* += size;
        return result;
    }
}
