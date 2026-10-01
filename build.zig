const std = @import("std");

const ThisBuild = @This();

pub const Options = struct {
    /// The target architecture for which the module will be built.
    target: ?std.Build.ResolvedTarget = null,
    /// The optimization mode used to compile the module.
    optimize: ?std.builtin.OptimizeMode = null,
    /// Explicit `bit_tree` module. When null, resolved via local `build.zig.zon` dependency.
    dependency_bit_tree: ?*std.Build.Module = null,

    pub fn initFromOptions(b: *std.Build) Options {
        return .{
            .target = b.standardTargetOptions(.{}),
            .optimize = b.standardOptimizeOption(.{}),
        };
    }

    /// Create the `resources_manager` module in the caller's build graph.
    ///
    /// Intended for parent packages that want a single shared instance:
    /// ```zig
    /// const rm_mod = (@import("resources_manager").Options{
    ///     .target = target,
    ///     .optimize = optimize,
    /// }).getModule(b);
    /// ```
    /// Uses `dependencyFromBuildZig` so source paths stay correct when
    /// called from a parent build via `@import("resources_manager")`.
    pub fn getModule(self: Options, b: *std.Build) *std.Build.Module {
        const target = self.target orelse b.standardTargetOptions(.{});
        const optimize = self.optimize orelse b.standardOptimizeOption(.{});
        const self_dep = b.dependencyFromBuildZig(ThisBuild, .{
            .target = target,
            .optimize = optimize,
        });
        const bit_tree_mod = self.dependency_bit_tree orelse self_dep.builder.dependency("bit_tree", .{
            .target = target,
            .optimize = optimize,
        }).module("bit_tree");
        const mod = b.createModule(.{
            .root_source_file = self_dep.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("bit_tree", bit_tree_mod);
        return mod;
    }
};

/// Create the `resources_manager` module in the *own* package graph (standalone `zig build`).
/// Same wiring as `Options.getModule` but uses `b.path` (valid only for own build).
fn createModuleOwn(b: *std.Build, options: Options) *std.Build.Module {
    const target = options.target orelse b.standardTargetOptions(.{});
    const optimize = options.optimize orelse b.standardOptimizeOption(.{});
    const bit_tree_mod = options.dependency_bit_tree orelse b.dependency("bit_tree", .{
        .target = target,
        .optimize = optimize,
    }).module("bit_tree");
    const mod = b.addModule("resources_manager", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("bit_tree", bit_tree_mod);
    return mod;
}

pub fn build(b: *std.Build) void {
    const options = Options.initFromOptions(b);

    const mod = createModuleOwn(b, options);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
