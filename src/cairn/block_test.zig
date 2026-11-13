//! The block's promises: a plan written reads back as itself, and a reader
//! that never trusts the bytes reads any bytes to a plan or to `Malformed`,
//! refusing a block that does not end where its last record does.
const std = @import("std");
const shakedown = @import("shakedown");
const block = @import("block.zig");

const testing = std.testing;

fn clamp(comptime T: type, items: []const T, max: usize) []const T {
    return if (items.len > max) items[0..max] else items;
}

/// A plan within the block's bounds, its readers a well-formed index.
fn plan(s: *shakedown.Source, a: std.mem.Allocator) !block.Plan {
    var p = try shakedown.gen.any(s, block.Plan, a);
    const quests = try a.dupe(block.Quest, p.quests);
    for (quests) |*q| {
        q.roles = clamp(u16, q.roles, block.max_roles);
        const stages = try a.dupe(block.Stage, clamp(block.Stage, q.stages, block.max_stages));
        for (stages) |*st| {
            // What a stage names lies within its quest: the stages it comes
            // after, and the roles its terms read.
            const after = try a.dupe(u8, clamp(u8, st.after, 255));
            for (after) |*x| x.* = @intCast(x.* % stages.len);
            st.after = after;
            const reads = try a.dupe(block.RoleRead, if (q.roles.len == 0) &.{} else clamp(block.RoleRead, st.roles, block.max_roles));
            for (reads) |*x| x.role = @intCast(x.role % q.roles.len);
            st.roles = reads;
            st.active = clamp(u32, st.active, 255);
            st.keeps = clamp(u32, st.keeps, 255);
        }
        q.stages = stages;
    }
    p.quests = quests;
    // Readers: a monotone index over stages that exist.
    var real: std.ArrayList(block.StageRef) = .empty;
    for (quests, 0..) |q, qi| for (0..q.stages.len) |si| try real.append(a, .{ .quest = @intCast(qi), .stage = @intCast(si) });
    const refs = try a.dupe(block.StageRef, if (real.items.len == 0) &.{} else p.readers.stages);
    for (refs, 0..) |*r, i| r.* = real.items[i % real.items.len];
    p.readers.stages = refs;
    // Calls name stages that exist.
    const calls = try a.dupe(block.Call, p.calls);
    for (calls, 0..) |*c, i| {
        if (real.items.len == 0) {
            c.* = .none;
            continue;
        }
        const ref = real.items[i % real.items.len];
        switch (c.*) {
            .none => {},
            .since => |*x| {
                x.quest = ref.quest;
                x.stage = ref.stage;
            },
            .before => |*x| {
                x.quest = ref.quest;
                x.a = ref.stage;
                x.b = ref.stage;
            },
        }
    }
    p.calls = calls;
    const starts = try a.alloc(u32, shakedown.gen.intRange(s, usize, 1, 6));
    for (starts, 0..) |*st, i| st.* = @intCast(@min(i, p.readers.stages.len));
    starts[starts.len - 1] = @intCast(p.readers.stages.len);
    p.readers.starts = starts;
    return p;
}

test "any plan written reads back as itself" {
    try shakedown.check(testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            var state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer state.deinit();
            const a = state.allocator();
            const p = try plan(case.source, a);
            const bytes = try block.write(a, p);
            const back = try block.read(a, bytes);
            try testing.expectEqualDeep(p, back);
        }
    }.one, .{ .cases = 2000, .seed = 0xca1 });
}

test "any bytes read to a plan or Malformed, and a block reads whole or not at all" {
    try shakedown.check(testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            var state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer state.deinit();
            const a = state.allocator();
            const bytes = try block.write(a, try plan(case.source, a));
            var buffer: [1024]u8 = undefined;
            const mutated = shakedown.gen.mutated(case.source, &buffer, &.{bytes});
            _ = block.read(a, mutated) catch |err| switch (err) {
                error.Malformed => {},
                error.OutOfMemory => return err,
            };
            const longer = try std.mem.concat(a, u8, &.{ bytes, "\x00" });
            try testing.expectError(error.Malformed, block.read(a, longer));
            if (bytes.len > 0) try testing.expectError(error.Malformed, block.read(a, bytes[0 .. bytes.len - 1]));
        }
    }.one, .{ .cases = 3000, .seed = 0xca2 });
}
