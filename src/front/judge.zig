//! cairn's judges: each tag cairn defines held to the story, and refused in
//! cairn's words where its value is written. `after` names stages of the
//! quest it stands in, `follows` shared rules, and `active` and `keeps` the
//! host's activation keys, which its manifest lists as things of the kind
//! `activation` where it lists them.

const std = @import("std");
const riverrun = @import("riverrun-compiler");
const written = @import("written.zig");

const check = riverrun.check;
const Checker = check.Checker;
const Tagged = check.Schema.Tagged;
const Error = Checker.Error;

/// `after noticed, the_letter`: stages of this quest, its own or inherited, never the stage itself.
pub fn after(c: *Checker, t: Tagged) Error!void {
    const s = c.section(t.section.?);
    for (t.tag.values, 0..) |v, i| {
        if (t.part) |p| if (std.mem.eql(u8, s.parts[p].name, v)) {
            try c.err(t.tag.at(i), "`{s}` comes after itself", .{v});
            continue;
        };
        if (written.part(s.node, v) != null) continue;
        // what the quest inherits is asked only of a name it does not write
        const inherited = if (written.isQuest(s.*)) try written.inherited(c.arena, c.files, s.node) else &.{};
        for (inherited) |h| {
            if (std.mem.eql(u8, h.part.name.text, v)) break;
        } else try c.err(t.tag.at(i), "`{s}` is not a stage of `{s}`", .{ v, s.name });
    }
}

/// `active spawn_stranger`, `keeps pin_letter`: the host's activation keys.
pub fn keys(c: *Checker, t: Tagged) Error!void {
    const kind = try c.kindOf(written.activation, t.tag.key.span);
    for (t.tag.values, 0..) |v, i| {
        if (!isWord(v)) {
            try c.err(t.tag.at(i), "`{s}` names an activation key, letters, digits and `_`: `{s}` is not one", .{ t.tag.key.text, v });
        } else if (!c.knowsThing(kind, v)) try c.err(t.tag.at(i), "the host has no activation key `{s}`", .{v});
    }
}

/// `follows everyone`: `(quest rules)` sections.
pub fn follows(c: *Checker, t: Tagged) Error!void {
    for (t.tag.values, 0..) |v, i| {
        const id = c.sectionNamed(t.module, v) orelse return c.err(t.tag.at(i), "`{s}` is not a section", .{v});
        if (!written.isRules(c.section(id).*)) try c.err(t.tag.at(i), "`{s}` is not `(quest rules)`", .{v});
    }
}

fn isWord(v: []const u8) bool {
    if (v.len == 0) return false;
    for (v) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    return true;
}
