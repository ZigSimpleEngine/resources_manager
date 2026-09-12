/// Standard library import.
const std = @import("std");
/// Reference type import.
const ref_mod = @import("resource_ref.zig");
/// Reference import.
const ResourceRef = ref_mod.ResourceRef;
/// Null reference import.
const NO_REF = ref_mod.NO_REF;
/// Pool import.
const SlotPool = @import("pool.zig").SlotPool;

/// Creates an ECS-compatible component that references a pooled resource.
///
/// The component stores only a `ResourceRef` (4 bytes, plain data), so it fits
/// the ECS rule "components are copyable value structs" used across every
/// component in this architecture: resource -> abstraction -> component holding
/// a reference to the pooled abstraction. Resolution goes through the global
/// `SlotPool(resource_type)`, therefore `get` needs no pool parameter.
///
/// Parameters:
/// - `resource_type`: pooled record type, e.g. an abstraction struct or a
///   direct pointer such as `*Texture` for non-generic types.
/// Returns: component struct type with a `ref` field and resolving accessors.
pub fn EcsResource(comptime resource_type: type) type {
    return struct {
        /// Reference to the pooled resource. `NO_REF` means "no resource".
        ref: ResourceRef = NO_REF,

        /// Pooled record type this component points at.
        pub const Resource = resource_type;

        /// Resolves the reference to the pooled resource.
        /// Parameters:
        /// - self: component to resolve.
        /// Returns: pointer to the resource, or null when removed or the
        /// generation mismatches (stale reference).
        pub fn get(self: @This()) ?*resource_type {
            return SlotPool(resource_type).get(self.ref);
        }

        /// Resolves the reference to the pooled resource (read-only).
        /// Parameters:
        /// - self: component to resolve.
        /// Returns: const pointer to the resource, or null when removed or stale.
        pub fn getConst(self: @This()) ?*const resource_type {
            return SlotPool(resource_type).getConst(self.ref);
        }

        /// Checks whether the referenced slot is live with a matching generation.
        /// Parameters:
        /// - self: component to inspect.
        /// Returns: true for a live, generation-matching slot.
        pub fn isAlive(self: @This()) bool {
            return SlotPool(resource_type).isAlive(self.ref);
        }
    };
}

test "ecs resource component resolves and goes stale" {
    const R = struct { v: i32 };
    const P = SlotPool(R);
    const C = EcsResource(R);
    const alloc = std.testing.allocator;
    defer P.deinit(alloc);

    const empty = C{};
    try std.testing.expect(empty.get() == null);
    try std.testing.expect(!empty.isAlive());

    const comp = C{ .ref = try P.add(alloc, .{ .v = 7 }) };
    try std.testing.expect(comp.isAlive());
    try std.testing.expectEqual(@as(i32, 7), comp.get().?.v);

    comp.get().?.v = 9;
    try std.testing.expectEqual(@as(i32, 9), comp.getConst().?.v);

    _ = try P.remove(alloc, comp.ref);
    try std.testing.expect(comp.get() == null); // stale after remove
    try std.testing.expect(!comp.isAlive());

    // recycled slot with a bumped generation does not resurrect the old component
    const comp2 = C{ .ref = try P.add(alloc, .{ .v = 1 }) };
    try std.testing.expect(comp.get() == null);
    try std.testing.expectEqual(@as(i32, 1), comp2.get().?.v);
}
