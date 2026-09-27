/// Standard library import.
const std = @import("std");

/// Creates an ECS-compatible resource reference to a value stored in a `SlotPool`.
///
/// The reference stores only `id` + `gen` (4 bytes, plain copyable data), so it
/// fits the ECS rule "components are copyable value structs" used across every
/// component in this architecture: resource -> abstraction -> component holding
/// the pooled abstraction. Resolution goes through the global
/// `SlotPool(resource_type)`, therefore `get` needs no pool parameter.
///
/// The `id` is the stable slot index: it never changes while the slot is
/// occupied and is recycled through the free list after removal. The `gen`
/// (generation) is bumped (`+%= 1`) on every removal, so a stale reference
/// to a recycled slot is detected by a simple `gen` comparison and treated
/// as dead.
///
/// Parameters:
/// - `resource_type`: pooled record type, e.g. an abstraction struct or a
///   direct pointer such as `*Texture` for non-generic types.
/// Returns: reference struct type with resolving accessors.
pub fn Resource(comptime resource_type: type) type {
    return packed struct {
        /// Stable slot index inside the pool. Defaults to the null sentinel.
        id: u24 = std.math.maxInt(u24),
        /// Slot generation at the time the reference was issued.
        gen: u8 = 0,

        /// Null (empty) reference: never matches a live slot (`get` rejects it
        /// by bounds check). `Resource(resource_type){}` equals this value.
        pub const NULL: @This() = .{ .id = std.math.maxInt(u24), .gen = 0 };

        /// Checks whether this is the null (empty) reference.
        /// Parameters:
        /// - self: reference to inspect.
        /// Returns: true for `NULL`.
        pub fn isNull(self: @This()) bool {
            return self.id == std.math.maxInt(u24);
        }

        /// Resolves the reference to the pooled resource.
        /// Parameters:
        /// - self: reference to resolve.
        /// Returns: pointer to the resource, or null when removed or the
        /// generation mismatches (stale reference).
        pub fn get(self: @This()) ?*resource_type {
            return @import("pool.zig").SlotPool(resource_type).get(self);
        }

        /// Checks whether the referenced slot is live with a matching generation.
        /// Parameters:
        /// - self: reference to inspect.
        /// Returns: true for a live, generation-matching slot.
        pub fn isAlive(self: @This()) bool {
            return @import("pool.zig").SlotPool(resource_type).isAlive(self);
        }
    };
}

test "resource null sentinel" {
    const R = struct { v: i32 };
    const Res = Resource(R);
    try std.testing.expect(Res.NULL.isNull());
    try std.testing.expect((Res{}).isNull());
    try std.testing.expect(!(Res{ .id = 0, .gen = 0 }).isNull());
    try std.testing.expect(@sizeOf(Res) == 4);
}

test "resource resolves and goes stale" {
    const R = struct { v: i32 };
    const P = @import("pool.zig").SlotPool(R);
    const alloc = std.testing.allocator;
    defer P.deinit(alloc);

    const empty: P.Resource = .{};
    try std.testing.expect(empty.get() == null);
    try std.testing.expect(!empty.isAlive());

    const res: P.Resource = try P.add(alloc, .{ .v = 7 });
    try std.testing.expect(res.isAlive());
    try std.testing.expectEqual(@as(i32, 7), res.get().?.v);

    res.get().?.v = 9;
    try std.testing.expectEqual(@as(i32, 9), res.get().?.v);

    _ = try P.remove(alloc, res);
    try std.testing.expect(res.get() == null); // stale after remove
    try std.testing.expect(!res.isAlive());

    // recycled slot with a bumped generation does not resurrect the old reference
    const res2: P.Resource = try P.add(alloc, .{ .v = 1 });
    try std.testing.expect(res.get() == null);
    try std.testing.expectEqual(@as(i32, 1), res2.get().?.v);
}
