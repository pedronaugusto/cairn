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
    front_tests.root_module.addAnonymousImport("quest-seeds", .{ .root_source_file = questSeeds(b, package) });
    // The whole compiler's property: riverrun's tools put a story through all of it.
    front_tests.root_module.addImport("riverrun-tools", riverrun.tools(package.builder.dependency("riverrun", .{ .target = target, .optimize = optimize })) orelse return);
    test_step.dependOn(&b.addRunArtifact(front_tests).step);
    test_step.dependOn(&b.addRunArtifact(storyTests(b, package, filters) orelse return).step);
    docs(b, test_step) orelse return;
    manualTests(b, test_step) orelse return;
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

/// The stories cairn's documentation shows: each checked by `riverrun check` with the game's vocabulary of
/// cairn's development, and every story the documents show rows of one of them.
const documented = struct {
    const stories = [_][]const u8{ "docs/examples/the_stranger.river", "docs/examples/written.river", "docs/examples/vocabulary.river", "docs/examples/board.river" };
    const documents = [_][]const u8{ "docs/design.md", "src/front/written.zig", "src/front/vocabulary.zig" };
};

/// What `riverrun play` writes for the design's quest under `tools/testdata/the_stranger.play`.
const the_stranger_played =
    \\> :set name(stranger) = "Tom"
    \\! roles the_stranger
    \\  stranger = stranger, standing in for the game's
    \\== asking
    \\* 1 Ask Margaret.
    \\* 2 Ask nobody.
    \\> :set met = true
    \\! started the_stranger
    \\! reached the_stranger.noticed
    \\  A man nobody knows stood at the foot of the coffin.
    \\! active spawn_stranger for the_stranger
    \\* 1 Ask Margaret.
    \\* 2 Ask nobody.
    \\> :set found += letter
    \\! reached the_stranger.the_letter
    \\  A letter signed "L.", from a city she never lived in.
    \\! inactive spawn_stranger for the_stranger
    \\! active pin_letter for the_stranger
    \\* 1 Ask Margaret.
    \\* 2 Ask nobody.
    \\> :facts the_stranger.noticed the_stranger.the_letter
    \\  the_stranger.noticed = true
    \\  the_stranger.the_letter = true
    \\> :set said += gave
    \\! reached the_stranger.the_hands
    \\  He said the hands were the same.
    \\! inactive pin_letter for the_stranger
    \\! reached the_stranger.named
    \\  He was Tom, her son, from a life she didn't live.
    \\  [carried += his_name]
    \\  ? name(stranger) = "Tom"
    \\! ended the_stranger.named
    \\* 1 Ask Margaret.
    \\* 2 Ask nobody.
    \\> 1
    \\[the_stranger.asked += margaret]
    \\-> end
    \\> :facts
    \\  met = true
    \\  found = letter
    \\  said = gave
    \\  carried = his_name
    \\  the_stranger.stranger = stranger
    \\  the_stranger.asked = margaret
    \\  the_stranger.noticed = true
    \\  the_stranger.the_letter = true
    \\  the_stranger.the_hands = true
    \\  the_stranger.named = true
    \\
;

/// What `riverrun play` writes for `tools/testdata/board.play`: the game's calls into cairn as the play's commands.
const board_played =
    \\== board
    \\* 1 Look at the board. ^c1
    \\* 2 Leave. ^c2
    \\> :start delivery giver=hilde
    \\! started delivery
    \\! reached delivery.taken
    \\  A letter for the mill, from .
    \\  ? name(hilde) = "" (not set)
    \\* 1 Look at the board. ^c1
    \\* 2 Leave. ^c2
    \\> :start bounty target=wolf
    \\! started bounty(1)
    \\! reached bounty(1).posted
    \\  A price on .
    \\  ? name(wolf) = "" (not set)
    \\! active pin_target for bounty(1)
    \\* 1 Look at the board. ^c1
    \\* 2 Leave. ^c2
    \\> :start bounty target = ulf
    \\! started bounty(2)
    \\! reached bounty(2).posted
    \\  A price on .
    \\  ? name(ulf) = "" (not set)
    \\! active pin_target for bounty(2)
    \\* 1 Look at the board. ^c1
    \\* 2 Leave. ^c2
    \\> :set dead(wolf) = true
    \\! reached bounty(1).claimed
    \\  Paid.
    \\  [gold += 50]
    \\! ended bounty(1).claimed
    \\! inactive pin_target for bounty(1)
    \\! reached delivery.delivered
    \\  Delivered, and paid for.
    \\! ended delivery.delivered
    \\* 1 Look at the board. ^c1
    \\* 2 Leave. ^c2
    \\> :wait 4
    \\! reached bounty(2).expired
    \\  The board took the notice down.
    \\! failed bounty(2).expired
    \\! inactive pin_target for bounty(2)
    \\* 1 Look at the board. ^c1
    \\* 2 Leave. ^c2
    \\> 2
    \\-> end
    \\
;

fn docs(b: *std.Build, test_step: *std.Build.Step) ?void {
    const package = b.dependency("cairn", riverrun.building(b));
    const river = b.dependency("riverrun", riverrun.building(b));
    const program = riverrun.addProgram(b, river, .{
        .vocabulary = package.path("tools/vocabulary.zig"),
        .packages = &.{.{ .name = "cairn-compiler", .module = compiler(package) orelse return null }},
    });
    for (documented.stories) |story| test_step.dependOn(&riverrun.addCheck(b, program, &.{package.path(story)}, .{}).step);
    // the design's quest played as a game plays it, its runtime run: the transcript pinned
    const played = b.addRunArtifact(program);
    played.addArgs(&.{ "play", "--set", "name(stranger) = \"Tom\"", "--script" });
    played.addFileArg2(package.path("tools/testdata/the_stranger.play"), .{});
    played.addFileArg2(package.path("docs/examples/the_stranger.river"), .{});
    played.setStdIn(.{ .bytes = "" });
    played.expectExitCode(0);
    played.expectStdOutEqual(the_stranger_played);
    test_step.dependOn(&played.step);
    // a quest the game starts, and a repeat quest it starts twice, through cairn's commands
    const board = b.addRunArtifact(program);
    board.addArgs(&.{ "play", "--script" });
    board.addFileArg2(package.path("tools/testdata/board.play"), .{});
    board.addFileArg2(package.path("docs/examples/board.river"), .{});
    board.setStdIn(.{ .bytes = "" });
    board.expectExitCode(0);
    board.expectStdOutEqual(board_played);
    test_step.dependOn(&board.step);
    const excerpts = riverrun.addExcerptsTest(b, river, .{ .package = package.builder, .stories = &documented.stories, .documents = &documented.documents }) orelse return null;
    test_step.dependOn(&b.addRunArtifact(excerpts).step);
}

/// The chapter of riverrun's manual that is cairn's, quests: the stories it shows, the runs of the program it shows
/// and the stories the checker refuses in them, kept as riverrun's manual keeps its chapters (its README, "How this
/// manual is kept"). Every story under `stories/` checks and prints nothing.
const manual = struct {
    const vocabulary = "docs/manual/stories/vocabulary.zig";
    const documents = [_][]const u8{"docs/manual/10-quests.md"};
    const stories = [_][]const u8{ "docs/manual/stories/10/errand.river", "docs/manual/stories/10/fair.river" };
    const runs = [_]riverrun.ShownRun{
        .{ .dir = "docs/manual/stories/10", .args = &.{ "play", "-i", "1", "-i", "3", "-i", "1", "-i", "1", "-i", "1", "-i", "1", "-i", "2", "-i", "1", "-i", "3", "errand.river" }, .output = "errand.transcript" },
        .{ .dir = "docs/manual/stories/10", .args = &.{ "play", "-i", "1", "-i", "2", "-i", "3", "errand.river" }, .output = "lost.transcript" },
        .{ .dir = "docs/manual/stories/10", .args = &.{ "play", "-i", ":bind cutpurse thief=pip", "-i", ":facts cutpurse.thief", "-i", ":set name(pip) = \"Pip\"", "-i", "3", "-i", ":set caught(pip) = true", "-i", "4", "fair.river" }, .output = "cutpurse.transcript" },
        .{ .dir = "docs/manual/stories/10", .args = &.{ "play", "-i", ":help", "fair.river" }, .output = "help.transcript", .status = 3 },
        .{ .dir = "docs/manual/stories/10", .args = &.{ "play", "-i", ":start parcel", "fair.river" }, .output = "refused.transcript", .status = 1 },
        .{ .dir = "docs/manual/stories/10", .args = &.{ "play", "--set", "name(miller) = \"Mrs Miller\"", "--call", "start parcel to=miller", "--script", "fair.play", "fair.river" }, .output = "fair.transcript" },
        .{ .dir = "docs/manual/mistakes/10", .args = &.{ "check", "fair.river" }, .output = "fair.diagnostics", .status = 1 },
        .{ .dir = "docs/manual/mistakes/10/ends", .args = &.{ "check", "fair.river" }, .output = "fair.diagnostics", .status = 1 },
    };
};

// The manual's stories checked, each printing nothing; its runs pinned; what its chapter shows held to them: in the
// test step, and alone in `manual-test`. `bay manual` installs the program its stories are written for.
fn manualTests(b: *std.Build, tests: *std.Build.Step) ?void {
    const package = b.dependency("cairn", riverrun.building(b));
    const river = b.dependency("riverrun", riverrun.building(b));
    const program = riverrun.addProgram(b, river, .{
        .vocabulary = package.path(manual.vocabulary),
        .packages = &.{.{ .name = "cairn-compiler", .module = compiler(package) orelse return null }},
    });
    b.step("manual", "The riverrun program the manual's stories are written for, into zig-out/bin").dependOn(&b.addInstallArtifact(program, .{}).step);
    const test_step = b.step("manual-test", "The manual's stories checked, its runs pinned, and what its chapter shows held to them");
    tests.dependOn(test_step);
    for (manual.stories) |story| {
        const clean = riverrun.addCheck(b, program, &.{package.path(story)}, .{});
        clean.expectStdOutEqual("");
        test_step.dependOn(&clean.step);
    }
    riverrun.addShownRuns(b, test_step, program, package.builder, &manual.runs);
    // a story the chapter shows the checker warn about checks too, and a ```river block may show it
    var checked: std.ArrayList([]const u8) = .empty;
    checked.appendSlice(b.allocator, &manual.stories) catch @panic("OOM");
    for (manual.runs) |r| if (r.status == 0 and std.mem.eql(u8, r.args[0], "check")) for (r.args[1..]) |a| {
        if (std.mem.endsWith(u8, a, ".river")) checked.append(b.allocator, b.pathJoin(&.{ r.dir, a })) catch @panic("OOM");
    };
    const excerpts = riverrun.addExcerptsTest(b, river, .{
        .package = package.builder,
        .stories = checked.items,
        .documents = &manual.documents,
        .runs = &manual.runs,
        .sources = &.{manual.vocabulary},
        .every = true,
    }) orelse return null;
    test_step.dependOn(&b.addRunArtifact(excerpts).step);
}

// The stories' text, each a `[]const u8` in `all`, for the properties that start from real quests.
fn questSeeds(b: *std.Build, package: *std.Build.Dependency) std.Build.LazyPath {
    const files = b.addWriteFiles();
    var root: std.ArrayList(u8) = .empty;
    root.appendSlice(b.allocator, "//! The stories cairn's development compiles, as text.\npub const all = [_][]const u8{\n") catch @panic("OOM");
    for (stories) |s| {
        _ = files.addCopyFile(package.path(s.file), b.fmt("{s}.river", .{s.name}));
        root.print(b.allocator, "    @embedFile(\"{s}.river\"),\n", .{s.name}) catch @panic("OOM");
    }
    root.appendSlice(b.allocator, "};\n") catch @panic("OOM");
    return files.add("seeds.zig", root.items);
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
