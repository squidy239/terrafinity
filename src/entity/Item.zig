const std = @import("std");

const Key = @import("../Key.zig");
const Block = @import("../world/Block.zig").Block;
const Cone = @import("../world/structures/Cone.zig").Cone;
const Sphere = @import("../world/structures/Sphere.zig").Sphere;
const World = @import("../world/World.zig");
const Entity = @import("Entity.zig");
const utils = @import("../libs/utils.zig");

pub const Inventory = struct {
    lock: std.Io.RwLock = .init,
    width: u32,
    height: u32,
    items: []?Item,

    pub fn initBuffer(width: u32, height: u32, buffer: []?Item) Inventory {
        std.debug.assert(buffer.len == width * height);
        @memset(buffer, null);
        return .{
            .width = width,
            .height = height,
            .items = buffer,
        };
    }

    pub fn get(self: *Inventory, io: std.Io, row: u32, col: u32) ?Item {
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);
        std.debug.assert(row < self.height and col < self.width);
        const index = (row * self.width) + col;
        return self.items[index];
    }

    pub fn set(self: *Inventory, io: std.Io, row: u32, col: u32, item: Item) ?Item {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        std.debug.assert(row < self.height and col < self.width);
        const index = (row * self.width) + col;
        const previous = self.items[index];
        self.items[index] = item;
        return previous;
    }

    pub fn swap(self: *Inventory, io: std.Io, row1: u32, col1: u32, row2: u32, col2: u32) void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        std.debug.assert(row1 < self.height and col1 < self.width);
        std.debug.assert(row2 < self.height and col2 < self.width);
        const index1 = (row1 * self.width) + col1;
        const index2 = (row2 * self.width) + col2;
        const temp = self.items[index1];
        self.items[index1] = self.items[index2];
        self.items[index2] = temp;
    }
};

/// Debug cone the place-rod item digs and builds with.
const rod_length: f32 = 100;
const rod_radius: f32 = 10;

pub const Item = struct {
    item_type: ItemType,
    amount: u32,
    /// Per-instance item data (durability, contents) held by an entity, or null
    /// for a plain stack. A weak handle: the owning container must hold the ref.
    data: ?Entity.Handle = null,

    /// Edits `ctx.editor` for this frame's inputs. Block items do nothing.
    pub fn use(self: Item, ctx: UseContext, actions: Key.ActionSet) !void {
        switch (self.item_type) {
            .PlaceRod => {
                const rod: Cone(f32) = .init(@floatCast(ctx.player_pos), ctx.looking, rod_length, rod_radius, rod_radius);
                if (actions.contains(.use_item_primary)) try ctx.editor.placeSamplerShape(.air, rod, World.standard_level);
                if (actions.contains(.use_item_secondary)) try ctx.editor.placeSamplerShape(.stone, rod, World.standard_level);
            },
            .PlaceSphere => {
                // Primary/secondary are the mouse "use" inputs; tertiary keeps the
                // old F key working through the item instead of a hardcoded sphere.
                if (actions.contains(.use_item_primary) or actions.contains(.use_item_secondary) or actions.contains(.use_item_tertiary)) {
                    const sphere: Sphere(f32) = .init(@floatCast(ctx.player_pos), @floatFromInt(ctx.sphere_size));
                    try ctx.editor.placeSamplerShape(ctx.sphere_block, sphere, World.standard_level);
                }
            },
            else => {},
        }
    }
};

/// Inputs and world state for one `Item.use`. The caller owns `editor` and flushes it.
pub const UseContext = struct {
    editor: *World.Editor,
    player_pos: @Vector(3, f64),
    looking: @Vector(3, f32),
    sphere_size: u32,
    sphere_block: Block,
};

/// Visible blocks in declaration order; `BlockItemType` holds one variant per
/// entry, so only placeable blocks become items (air/null/fine_grass are skipped).
pub const block_types: [Block.visible_count]Block = blk: {
    var list: [Block.visible_count]Block = undefined;
    var count: usize = 0;
    for (std.meta.fields(Block)) |field| {
        const block: Block = @field(Block, field.name);
        if (!block.isVisible()) continue;
        list[count] = block;
        count += 1;
    }
    break :blk list;
};

/// Item variants for placeable blocks, generated from `block_types` at comptime,
/// so adding a visible `Block` adds an item variant with no edits here.
pub const BlockItemType = blk: {
    var names: [block_types.len][]const u8 = undefined;
    var values: [block_types.len]u16 = undefined;
    for (block_types, 0..) |block, i| {
        names[i] = @tagName(block);
        values[i] = @intCast(i);
    }
    break :blk @Enum(u16, .exhaustive, &names, &values);
};

/// Items with no block form. Add variants here; `ItemType` picks them up.
pub const ExtraItemType = enum(u16) {
    Explosive,
    PlaceRod,
    PlaceSphere,
};

/// Every item, block-backed and extra, in one u16-backed enum.
pub const ItemType = utils.joinEnums(u16, &.{ BlockItemType, ExtraItemType });

/// Item form of every extra item, in declaration order.
pub const extra_item_types: [std.meta.fields(ExtraItemType).len]ItemType = blk: {
    var list: [std.meta.fields(ExtraItemType).len]ItemType = undefined;
    for (&list, 0..) |*slot, i| slot.* = @enumFromInt(block_types.len + i);
    break :blk list;
};

/// The item form of a placeable block, or null for invisible blocks.
pub fn fromBlock(block: Block) ?ItemType {
    const index = std.mem.indexOfScalar(Block, &block_types, block) orelse return null;
    return @enumFromInt(index);
}

/// The block a block item places, or null for extra items.
pub fn toBlock(item_type: ItemType) ?Block {
    const index = @intFromEnum(item_type);
    if (index >= block_types.len) return null;
    return block_types[index];
}

test "ItemType covers every visible block" {
    inline for (std.meta.fields(Block)) |field| {
        const block: Block = @field(Block, field.name);
        if (!block.isVisible()) continue;
        const item_type = fromBlock(block) orelse return error.MissingItemType;
        try std.testing.expectEqual(block, toBlock(item_type).?);
    }
    try std.testing.expectEqual(@as(?Block, null), toBlock(.Explosive));
}

test "ItemType is u16-backed and includes extras" {
    try std.testing.expect(@bitSizeOf(@typeInfo(ItemType).@"enum".tag_type) == 16);
    try std.testing.expectEqual(@as(u16, @intCast(block_types.len)), @intFromEnum(ItemType.Explosive));
}

test "extra item types are the non-block items in order" {
    try std.testing.expectEqual(ItemType.Explosive, extra_item_types[0]);
    try std.testing.expectEqual(ItemType.PlaceRod, extra_item_types[1]);
    try std.testing.expectEqual(ItemType.PlaceSphere, extra_item_types[2]);
}

test "tool items have no block form" {
    try std.testing.expectEqual(@as(?Block, null), toBlock(.PlaceRod));
    try std.testing.expectEqual(@as(?Block, null), toBlock(.PlaceSphere));
}

test "Item data is a weak entity handle" {
    const item: Item = .{ .item_type = .stone, .amount = 1 };
    try std.testing.expectEqual(@as(?Entity.Handle, null), item.data);
    _ = Entity.Handle;
}

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
