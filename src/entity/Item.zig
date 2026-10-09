const std = @import("std");

const Key = @import("../Key.zig");
const Block = @import("../world/Block.zig").Block;
const Cone = @import("../world/structures/Cone.zig").Cone;
const Sphere = @import("../world/structures/Sphere.zig").Sphere;
const World = @import("../world/World.zig");
const Entity = @import("Entity.zig");
const utils = @import("../libs/utils.zig");

/// An item grid. Its owner drives it from one thread, so it needs no lock.
pub const Inventory = struct {
    width: u32,
    /// Row-major, `width * height()` slots.
    items: []?Item,

    /// Allocates an empty `width` by `rows` grid.
    pub fn init(allocator: std.mem.Allocator, width: u32, rows: u32) !Inventory {
        const items = try allocator.alloc(?Item, @as(usize, width) * rows);
        @memset(items, null);
        return .{ .width = width, .items = items };
    }

    /// Number of rows.
    pub fn height(self: *const Inventory) u32 {
        return @intCast(self.items.len / self.width);
    }

    /// Frees the slots.
    pub fn deinit(self: *Inventory, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
    }

    /// The item in a slot, or null when it is empty.
    pub fn get(self: *const Inventory, row: u32, col: u32) ?Item {
        return self.items[self.index(row, col)];
    }

    /// The slots of one row, left to right.
    pub fn rowSlots(self: *const Inventory, row: u32) []const ?Item {
        return self.items[self.index(row, 0)..][0..self.width];
    }

    /// Replaces the item in a slot; null empties it.
    pub fn set(self: *Inventory, row: u32, col: u32, item: ?Item) void {
        self.items[self.index(row, col)] = item;
    }

    fn index(self: *const Inventory, row: u32, col: u32) usize {
        std.debug.assert(row < self.height() and col < self.width);
        return @as(usize, row) * self.width + col;
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

    /// Edits `editor` for this frame's inputs. Block items do nothing. The caller flushes `editor`.
    pub fn use(self: Item, editor: *World.Editor, ctx: UseContext) !void {
        switch (self.item_type) {
            .PlaceRod => {
                const rod: Cone(f32) = .init(@floatCast(ctx.player_pos), ctx.looking, rod_length, rod_radius, rod_radius);
                if (ctx.actions.contains(.use_item_primary)) try editor.placeSamplerShape(.air, rod, World.standard_level);
                if (ctx.actions.contains(.use_item_secondary)) try editor.placeSamplerShape(.stone, rod, World.standard_level);
            },
            .PlaceSphere => {
                // Primary/secondary are the mouse "use" inputs; tertiary keeps the
                // old F key working through the item instead of a hardcoded sphere.
                if (ctx.actions.contains(.use_item_primary) or ctx.actions.contains(.use_item_secondary) or ctx.actions.contains(.use_item_tertiary)) {
                    const sphere: Sphere(f32) = .init(@floatCast(ctx.player_pos), @floatFromInt(ctx.sphere_size));
                    try editor.placeSamplerShape(ctx.sphere_block, sphere, World.standard_level);
                }
            },
            else => {},
        }
    }
};

/// A copy of the inputs and player state for one `Item.use`, taken on the frame
/// thread so the use can run on another task.
pub const UseContext = struct {
    actions: Key.ActionSet,
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
    for (@typeInfo(Block).@"enum".field_names) |name| {
        const block: Block = @field(Block, name);
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
    for (block_types, &names, &values, 0..) |block, *name, *value, i| {
        name.* = @tagName(block);
        value.* = @intCast(i);
    }
    break :blk @Enum(u16, .exhaustive, &names, &values);
};

/// Items with no block form. `ItemType` picks up each variant added here.
pub const ExtraItemType = enum(u16) {
    Explosive,
    PlaceRod,
    PlaceSphere,
};

/// Every item, block-backed and extra, in one u16-backed enum.
pub const ItemType = utils.joinEnums(u16, &.{ BlockItemType, ExtraItemType });

/// Item form of every extra item, in declaration order.
pub const extra_item_types: [@typeInfo(ExtraItemType).@"enum".field_names.len]ItemType = blk: {
    var list: [@typeInfo(ExtraItemType).@"enum".field_names.len]ItemType = undefined;
    for (&list, 0..) |*slot, i| slot.* = @fromBackingInt(@intCast(block_types.len + i));
    break :blk list;
};

/// The item form of a placeable block, or null for invisible blocks.
pub fn fromBlock(block: Block) ?ItemType {
    const index = std.mem.findScalar(Block, &block_types, block) orelse return null;
    return @fromBackingInt(@intCast(index));
}

/// The block a block item places, or null for extra items.
pub fn toBlock(item_type: ItemType) ?Block {
    const index = @backingInt(item_type);
    if (index >= block_types.len) return null;
    return block_types[index];
}

test "ItemType covers every visible block" {
    inline for (@typeInfo(Block).@"enum".field_names) |name| {
        const block: Block = @field(Block, name);
        if (!block.isVisible()) continue;
        const item_type = fromBlock(block) orelse return error.MissingItemType;
        try std.testing.expectEqual(block, toBlock(item_type).?);
    }
    for (extra_item_types) |item_type| try std.testing.expectEqual(@as(?Block, null), toBlock(item_type));
}

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
