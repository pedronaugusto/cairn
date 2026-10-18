//! The active set: every key an active instance keeps active, the content
//! of the world its quest turns on (a person present, a door open, a
//! marker). It is derived from the facts, never saved, and a host reconciles
//! its world to it rather than to events that a load would lose.

const std = @import("std");
const Instance = @import("ids.zig").Instance;

const Active = @This();

/// A key as the host knows it: the handle it resolved the story's text id to, and the id.
pub const Key = struct { handle: u64, name: []const u8 };

/// One key an instance keeps active.
pub const Entry = struct {
    instance: Instance,
    key: Key,
    /// The story's thing the key is, by its place in the story's things.
    thing: u32,
};

list: std.ArrayList(Entry) = .empty,
/// Where each entry is in `list`, by its instance and thing.
at: std.AutoHashMapUnmanaged(Place, u32) = .empty,

const Place = struct { quest: u32, key: u64, thing: u32 };

fn placeOf(i: Instance, thing: u32) Place {
    return .{ .quest = i.quest.raw(), .key = i.key, .thing = thing };
}

pub fn deinit(a: *Active, gpa: std.mem.Allocator) void {
    a.list.deinit(gpa);
    a.at.deinit(gpa);
    a.* = undefined;
}

/// Adds the key; false when the instance keeps it active already.
pub fn give(a: *Active, gpa: std.mem.Allocator, i: Instance, thing: u32, key: Key) error{OutOfMemory}!bool {
    const gop = try a.at.getOrPut(gpa, placeOf(i, thing));
    if (gop.found_existing) return false;
    errdefer a.at.removeByPtr(gop.key_ptr);
    gop.value_ptr.* = @intCast(a.list.items.len); // safe: entries are fewer than a u32
    try a.list.append(gpa, .{ .instance = i, .key = key, .thing = thing });
    return true;
}

/// Takes the key away; the key it was, or null when the instance kept it active not.
pub fn take(a: *Active, gpa: std.mem.Allocator, i: Instance, thing: u32) error{OutOfMemory}!?Key {
    _ = gpa;
    const kv = a.at.fetchRemove(placeOf(i, thing)) orelse return null;
    const at = kv.value;
    const key = a.list.items[at].key;
    _ = a.list.swapRemove(at);
    if (at < a.list.items.len) {
        const moved = a.list.items[at];
        a.at.getPtr(placeOf(moved.instance, moved.thing)).?.* = at; // every entry has its place
    }
    return key;
}

test "keys are given and taken, each once an instance" {
    const gpa = std.testing.allocator;
    var a: Active = .{};
    defer a.deinit(gpa);
    const one: Instance = .{ .quest = .fromRaw(0), .key = 1 };
    const two: Instance = .{ .quest = .fromRaw(0), .key = 2 };
    try std.testing.expect(try a.give(gpa, one, 3, .{ .handle = 30, .name = "pin" }));
    try std.testing.expect(!try a.give(gpa, one, 3, .{ .handle = 30, .name = "pin" }));
    try std.testing.expect(try a.give(gpa, two, 3, .{ .handle = 30, .name = "pin" }));
    try std.testing.expect(try a.give(gpa, two, 4, .{ .handle = 40, .name = "gate" }));
    try std.testing.expectEqual(@as(u64, 30), (try a.take(gpa, one, 3)).?.handle);
    try std.testing.expectEqual(@as(?Key, null), try a.take(gpa, one, 3));
    try std.testing.expectEqual(@as(usize, 2), a.list.items.len);
    try std.testing.expectEqual(@as(u64, 40), (try a.take(gpa, two, 4)).?.handle);
    try std.testing.expect(a.list.items[0].instance.eql(two));
}
