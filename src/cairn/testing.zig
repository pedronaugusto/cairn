//! A story built by hand for the runtime's tests, as cairn's compile pass
//! would write it: one quest that starts itself, `noticed when { met }` and
//! `named when { noticed and told }`, its outcome, with the block that says
//! so. The compiler side's tests compile quests from their text; these need
//! riverrun's runtime alone.

const std = @import("std");
const riverrun = @import("riverrun");
const block = @import("block.zig");

const story = riverrun.story;
const Builder = story.Builder;
const Term = story.Term;

pub const Built = struct {
    graph: []u8,

    pub fn deinit(b: *Built, gpa: std.mem.Allocator) void {
        gpa.free(b.graph);
    }
};

/// The story, and its block as `edit` leaves the plan: a test that damages it says how.
pub fn build(gpa: std.mem.Allocator, edit: ?*const fn (*block.Plan) void) !Built {
    var b: Builder = try .init(gpa);
    defer b.deinit();
    const world = try b.scope("world");
    const met = try b.fact(.{ .name = "met", .scope = world, .kind = .boolean, .role = .game });
    const told = try b.fact(.{ .name = "told", .scope = world, .kind = .boolean, .role = .game });
    const gold = try b.fact(.{ .name = "gold", .scope = world, .kind = .int });
    const noticed = try b.fact(.{ .name = "q.noticed", .scope = world, .kind = .boolean, .role = .game });
    const named = try b.fact(.{ .name = "q.named", .scope = world, .kind = .boolean, .role = .game });
    const status = try b.fact(.{ .name = "q.@status", .scope = world, .kind = .one_of, .enumeration = try b.enumeration(&.{ "active", "done", "failed" }), .role = .game });
    const current = try b.fact(.{ .name = "q.@current", .scope = world, .kind = .one_of, .enumeration = try b.enumeration(&.{ "noticed", "named" }), .role = .game });
    const q = try b.section(.{ .name = "q", .kind = .other, .kind_name = "quest", .visits = null });
    b.enter(q, try b.node(.{ .step = .ret }));
    const a = try b.section(.{ .name = "q.noticed", .kind = .other, .kind_name = "quest", .visits = null });
    b.enter(a, try b.node(.{ .step = .ret }));
    // reaching `named` gives ten gold
    const z = try b.section(.{ .name = "q.named", .kind = .other, .kind_name = "quest", .visits = null });
    const pay = try b.effectList(&.{.{ .change = .{ .fact = gold, .by = try b.expr(&.{.of(.int, try b.int(10))}) } }});
    b.enter(z, try b.node(.{ .step = .{ .effects = .{ .effects = pay } } }));
    const when_a = try b.expr(&.{.of(.fact, met.raw())});
    const when_z = try b.expr(&.{ .of(.fact, noticed.raw()), .of(.fact, told.raw()), .of(.@"and", 0) });
    const stages = [_]block.Stage{
        .{ .section = a.raw(), .fact = noticed.raw(), .when = .{ .start = when_a.start, .len = when_a.len }, .kind = .stage },
        .{ .section = z.raw(), .fact = named.raw(), .when = .{ .start = when_z.start, .len = when_z.len }, .kind = .outcome, .after = &.{0} },
    };
    var plan: block.Plan = .{
        .quests = &.{.{ .section = q.raw(), .repeat = false, .starts_itself = true, .status = status.raw(), .current = current.raw(), .roles = &.{}, .stages = &stages }},
        .calls = &.{},
        .readers = .{ .starts = &.{}, .stages = &.{} },
    };
    if (edit) |e| e(&plan);
    const bytes = try block.write(gpa, plan);
    defer gpa.free(bytes);
    try b.block(block.name, block.version, bytes);
    return .{ .graph = try b.bytes(gpa) };
}
