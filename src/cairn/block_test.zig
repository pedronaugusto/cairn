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

// At most max_keys of them, drawn from max_keys keys, so a quest names at most max_keys in all.
fn keys(a: std.mem.Allocator, items: []const u32) ![]const u32 {
    const out = try a.dupe(u32, clamp(u32, items, block.max_keys));
    for (out) |*k| k.* %= block.max_keys;
    return out;
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
            // A quest names at most max_keys keys, its stages' `active` and `keeps` together.
            st.active = try keys(a, st.active);
            st.keeps = try keys(a, st.keeps);
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
    }.one, .{
        .cases = 2000,
        .seed = 0xca1,
        // stages whose `active` and `keeps` held more keys than the reader takes: the bound is now the quest's, kept
        // by the checker, the writer and the reader alike
        .regressions = &.{"5e17f:0:0:0:0:0:0:0:9ada4:0:0:0:0:0:0:0:0:0:a5102:0:e3d04:0:99b0a:0:cf262:0:b4b5e:0:e07b4:0:9e782:0:ab23b:0:eac69:0:c96cc:0:7de57:0:71b6d:0:dbda5:0:e20ac:0:cf8bd:0:e2314:0:33089:0:cd3f4:0:66c98:0:d43e3:0:a7a7d:0:c094d:0:dd9d1:0:5e119:0:52506:0:33db3:0:35395:0:59739:0:9cf95:0:42150:0:d48ed:0:d9751:0:47213:0:393f4:0:99637:0:9bed2:0:cae35:0:71cf4:0:ea419:0:cdbdc:0:ececa:ab42efe6:547cb:19953c54:b3996:905eb671:aeeae:bc7700da:3a37b:6bd32eed:6faf1:5bf67e39:add29:52d35dfc:a7175:a22d3e86:666aa:f9a49da5:44149:eb35ba98:a750d:c657e32f:ba7f2:7be70fed:a4e3b:596df0a4:a616c:2482121c:5ca74:b16a1850:bc69f:354c5363:7be29:f93fdecf:f1aa9:59054979:40d71:43a0337:359a4:4ce00786:c8a62:19a596be:75251:54db09ff:76728:d67d2853:afbe3:d60a115e:b207b"},
    });
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
