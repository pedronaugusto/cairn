const std = @import("std");
const riverrun = @import("riverrun");

/// What a host that depends on cairn builds: the `cairn` module, the executor, on riverrun's runtime. cairn's
/// compiler side, `cairn-compiler`, is `compiler`'s to make, on first ask, so a game that only runs quests never
/// fetches riverrun's compiler. The tests, the gate and the benchmark are `dev`'s.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = b.addModule("cairn", .{
        .root_source_file = b.path("src/cairn.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports(b, target, optimize),
    });
}

/// cairn's compiler side, `cairn-compiler`, of the cairn instance `dep`: what a story's vocabulary registers,
/// `cairn.package` (the `quest` and `quest rules` kinds, their tags and builtins, cairn's check and the pass that
/// writes its block), on the riverrun compiler of the riverrun instance cairn's own build stands on. Made on the
/// first ask and kept with the instance; null until riverrun's compiler is fetched. A story's build asks it of
/// cairn asked by `riverrun.building(b)`, and hands it to `riverrun.addStory` as `cairn-compiler`.
pub fn compiler(dep: *std.Build.Dependency) ?*std.Build.Module {
    const d = dep.builder;
    if (d.modules.get("cairn-compiler")) |m| return m;
    const runtime = dep.module("cairn");
    const target = runtime.resolved_target.?;
    const optimize = runtime.optimize.?;
    const river = d.dependency("riverrun", .{ .target = target, .optimize = optimize });
    return d.addModule("cairn-compiler", .{
        .root_source_file = d.path("src/front.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "riverrun-compiler", .module = riverrun.compiler(river) orelse return null },
            .{ .name = "riverrun", .module = river.module("riverrun") },
            .{ .name = "cairn", .module = runtime },
        },
    });
}

/// The stories cairn's development compiles through `addStory` with cairn registered, as a game's build does:
/// each the module of that name the story tests import.
const stories = [_]struct { name: []const u8, file: []const u8 }{
    .{ .name = "wake", .file = "tools/testdata/wake.river" },
    .{ .name = "givers", .file = "tools/testdata/givers.river" },
    .{ .name = "order", .file = "tools/testdata/order.river" },
    .{ .name = "bounties", .file = "tools/testdata/bounties.river" },
};

/// cairn's development: its tests under preflight's gate, the compiler side's beside the runtime's, stories
/// compiled through `addStory` with cairn registered and played, and the benchmark. Run through bay.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Select tests by name");
    const package = b.dependency("cairn", .{ .target = target, .optimize = optimize });
    const filters: []const []const u8 = if (test_filter) |filter| &.{filter} else &.{};
    const test_step = b.step("test", "Run the tests");
    const runtime_tests = b.addTest(.{ .name = "cairn-tests", .filters = filters, .root_module = package.module("cairn") });
    // The block's properties: shakedown, in the development graph alone.
    runtime_tests.root_module.addImport("shakedown", b.dependency("shakedown", .{ .target = target, .optimize = optimize }).module("shakedown"));
    test_step.dependOn(&b.addRunArtifact(runtime_tests).step);
    const front_tests = b.addTest(.{ .name = "cairn-compiler-tests", .filters = filters, .root_module = compiler(package) orelse return });
    // The quest reader's properties: shakedown, in the development graph alone.
    front_tests.root_module.addImport("shakedown", b.dependency("shakedown", .{ .target = target, .optimize = optimize }).module("shakedown"));
    test_step.dependOn(&b.addRunArtifact(front_tests).step);
    test_step.dependOn(&b.addRunArtifact(storyTests(b, package, filters) orelse return).step);
    tools.preflight.addCi(b, package.builder, .{
        .tests = test_step,
        .bench = .{
            .programs = &.{.{ .name = "quests", .source = "bench/quests.zig" }},
            .imports = tools.preflight.Bench.importsFrom(benchImports),
            .target = target,
            .optimize = optimize,
        },
    });
}

// The stories through `addStory`, their compiler and cairn's compiler side on one riverrun for the machine doing
// the building, then played by a test on the game's riverrun and cairn, which must be one too or it does not
// compile.
fn storyTests(b: *std.Build, package: *std.Build.Dependency, filters: []const []const u8) ?*std.Build.Step.Compile {
    const side = compiler(b.dependency("cairn", riverrun.building(b))) orelse return null;
    const runtime = package.module("cairn");
    const river = b.dependency("riverrun", .{ .target = runtime.resolved_target.?, .optimize = runtime.optimize.? });
    var list: std.ArrayList(std.Build.Module.Import) = .empty;
    list.appendSlice(b.allocator, &.{ .{ .name = "riverrun", .module = river.module("riverrun") }, .{ .name = "cairn", .module = runtime } }) catch @panic("OOM");
    for (stories) |s| {
        const story = riverrun.addStory(b, b.dependency("riverrun", riverrun.building(b)), .{
            .files = &.{package.path(s.file)},
            .vocabulary = package.path("tools/vocabulary.zig"),
            .packages = &.{.{ .name = "cairn-compiler", .module = side }},
            .name = s.name,
        });
        list.append(b.allocator, .{ .name = s.name, .module = story.module }) catch @panic("OOM");
    }
    return b.addTest(.{
        .name = "cairn-story-tests",
        .filters = filters,
        .root_module = b.createModule(.{
            .root_source_file = package.path("tools/story_test.zig"),
            .target = runtime.resolved_target,
            .optimize = runtime.optimize,
            .imports = list.items,
        }),
    });
}

/// cairn and its compiler side again, in the mode a benchmark builds in: an imported module keeps its own mode,
/// so a ReleaseFast benchmark over the Debug module would time the Debug module. `b` is the development build.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) []const std.Build.Module.Import {
    const package = b.dependency("cairn", .{ .target = target, .optimize = optimize });
    const p = package.builder;
    const river = p.dependency("riverrun", .{ .target = target, .optimize = optimize });
    return b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "cairn", .module = package.module("cairn") },
        .{ .name = "cairn-compiler", .module = compiler(package) orelse @panic("riverrun's compiler is not fetched") },
        .{ .name = "riverrun", .module = river.module("riverrun") },
        .{ .name = "riverrun-compiler", .module = riverrun.compiler(river) orelse @panic("riverrun's compiler is not fetched") },
    }) catch @panic("OOM");
}

fn imports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) []const std.Build.Module.Import {
    const aegis = b.dependency("aegis", .{ .target = target, .optimize = optimize });
    const river = b.dependency("riverrun", .{ .target = target, .optimize = optimize });
    return b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "aegis", .module = aegis.module("aegis") },
        .{ .name = "riverrun", .module = river.module("riverrun") },
    }) catch @panic("OOM");
}
