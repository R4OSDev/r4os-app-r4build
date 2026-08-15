const std = @import("std");

/// Eigenstaendiger Bau aus dem Manifest und den gepinnten Kernpaketen.
pub fn build(b: *std.Build) void {
    const sdk_build = b.lazyImport(@This(), "r4os_sdk") orelse return;
    const sdk_dep = b.dependencyFromBuildZig(sdk_build, .{});
    const r4cc_build = b.lazyImport(@This(), "r4os_r4cc") orelse return;
    const r4cc_dep = b.dependencyFromBuildZig(r4cc_build, .{});
    const r4pack_build = b.lazyImport(@This(), "r4os_r4pack") orelse return;
    const r4pack_dep = b.dependencyFromBuildZig(r4pack_build, .{});
    const sdk = sdk_build.sdk(b, sdk_dep, .{});
    _ = sdk.addR4MFWithOptions(b.path("module.R4MF"), .{
        .zig_module_roots = &.{
            r4cc_dep.namedLazyPath("r4code_cc_core"),
            r4pack_dep.namedLazyPath("r4code_pack_core"),
        },
    });
}