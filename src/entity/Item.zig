const std = @import("std");

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

    /// Gets an item at the given position in the inventory.
    pub fn get(self: *Inventory, io: std.Io, row: u32, col: u32) ?Item {
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);
        std.debug.assert(row < self.height and col < self.width);
        const index = (row * self.width) + col;
        return self.items[index];
    }

    /// Sets an item at the given position in the inventory and returns the
    /// old item, or null if the slot was empty.
    pub fn set(self: *Inventory, io: std.Io, row: u32, col: u32, item: Item) ?Item {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        std.debug.assert(row < self.height and col < self.width);
        const index = (row * self.width) + col;
        const previous = self.items[index];
        self.items[index] = item;
        return previous;
    }

    /// Swaps 2 items in the inventory, can be used as move if one item is null.
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

pub const Item = struct {
    item_type: ItemType,
    amount: u32,
    metadata: ?*MetaData = null,
};

pub const ItemType = enum {
    Explosive,
};

pub const MetaData = struct {};
