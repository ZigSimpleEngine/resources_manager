/// Standard library import.
const std = @import("std");

/// Lightweight reference to a resource stored in a `SlotPool`.
///
/// The `id` is the stable slot index: it never changes while the slot is
/// occupied and is recycled through the free list after removal. The `gen`
/// (generation) is bumped (`+%= 1`) on every removal, so a stale reference
/// to a recycled slot is detected by a simple `gen` comparison and treated
/// as dead. The whole reference is 4 bytes and freely copyable, which makes
/// it suitable for embedding into ECS components.
pub const ResourceRef = packed struct {
    /// Stable slot index inside the pool.
    id: u24,
    /// Slot generation at the time the reference was issued.
    gen: u8,

    /// Checks whether this is the null (empty) reference.
    /// Parameters:
    /// - self: reference to inspect.
    /// Returns: true for `NO_REF`.
    pub fn isNull(self: @This()) bool {
        return self.id == std.math.maxInt(u24);
    }
};

/// Null reference: never matches a live slot (`get` rejects it by bounds check).
pub const NO_REF: ResourceRef = .{ .id = std.math.maxInt(u24), .gen = 0 };

test "ref null sentinel" {
    try std.testing.expect(NO_REF.isNull());
    try std.testing.expect(!(ResourceRef{ .id = 0, .gen = 0 }).isNull());
    try std.testing.expect(@sizeOf(ResourceRef) == 4);
}
