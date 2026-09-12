/// Standard library import.
const std = @import("std");
/// Reference type import.
const ref_mod = @import("resource_ref.zig");
/// Lightweight reference import.
const ResourceRef = ref_mod.ResourceRef;

/// Creates a global per-type resource pool with stable ids.
///
/// Each instantiation `SlotPool(T)` owns its own static storage, so repeating
/// the same instantiation from any point of the program yields the same pool.
/// The pool only tracks resources: it never destroys the stored values.
///
/// Storage per pool:
/// - `slots` — resources, index == stable id;
/// - `free_ids` — ids of empty slots reused by the next `add`;
/// - `occupied` — occupancy bitmap, one bit per slot;
/// - `generations` — one byte per slot, bumped (`+%= 1`) on every `remove`.
///
/// Parameters:
/// - `T`: resource record type stored in the pool (e.g. an abstraction struct
///   or a direct pointer such as `*Texture` for non-generic types).
/// Returns: pool namespace with static storage and operations.
pub fn SlotPool(comptime T: type) type {
    return struct {
        /// Slot storage, index == stable id. `null` means the slot is free.
        var slots: std.ArrayListUnmanaged(?T) = .empty;
        /// Ids of free slots, reused by the next `add`.
        var free_ids: std.ArrayListUnmanaged(u32) = .empty;
        /// Occupancy bitmap, one bit per slot.
        var occupied: std.ArrayListUnmanaged(u64) = .empty;
        /// Generation byte per slot, bumped on every `remove`.
        var generations: std.ArrayListUnmanaged(u8) = .empty;
        /// Number of currently occupied slots.
        var live_count: usize = 0;

        /// Reads one occupancy bit.
        fn bitGet(words: []const u64, idx: usize) bool {
            return (words[idx / 64] & (@as(u64, 1) << @intCast(idx % 64))) != 0;
        }
        /// Sets one occupancy bit.
        fn bitSet(words: []u64, idx: usize) void {
            words[idx / 64] |= (@as(u64, 1) << @intCast(idx % 64));
        }
        /// Clears one occupancy bit.
        fn bitClear(words: []u64, idx: usize) void {
            words[idx / 64] &= ~(@as(u64, 1) << @intCast(idx % 64));
        }
        /// Grows the bitmap so it covers `idx`.
        fn ensureWord(alloc: std.mem.Allocator, idx: usize) !void {
            const need = idx / 64 + 1;
            if (occupied.items.len < need) try occupied.appendNTimes(alloc, 0, need - occupied.items.len);
        }

        /// Validates a reference against bounds, occupancy and generation.
        /// Parameters:
        /// - ref: reference to validate.
        /// Returns: slot index, or null when the reference is stale or empty.
        fn check(ref: ResourceRef) ?usize {
            if (ref.isNull()) return null;
            const id: usize = ref.id;
            if (id >= slots.items.len) return null;
            if (!bitGet(occupied.items, id)) return null;
            if (generations.items[id] != ref.gen) return null;
            return id;
        }

        /// Stores a value and returns a stable reference to it.
        /// Reuses an id from the free list when possible, otherwise appends.
        /// Parameters:
        /// - alloc: allocator for slot storage.
        /// - value: resource record to store.
        /// Returns: reference with the slot id and its current generation.
        pub fn add(alloc: std.mem.Allocator, value: T) !ResourceRef {
            if (free_ids.pop()) |id| {
                slots.items[id] = value;
                bitSet(occupied.items, id);
                live_count += 1;
                return .{ .id = @intCast(id), .gen = generations.items[id] };
            }
            const id: usize = slots.items.len;
            try slots.append(alloc, value);
            try generations.append(alloc, 0);
            try ensureWord(alloc, id);
            bitSet(occupied.items, id);
            live_count += 1;
            return .{ .id = @intCast(id), .gen = 0 };
        }

        /// Resolves a reference to the stored value.
        /// Parameters:
        /// - ref: reference to resolve.
        /// Returns: pointer to the value, or null when removed or generation mismatched.
        pub fn get(ref: ResourceRef) ?*T {
            const id = check(ref) orelse return null;
            return &slots.items[id].?;
        }

        /// Resolves a reference to the stored value (read-only).
        /// Parameters:
        /// - ref: reference to resolve.
        /// Returns: const pointer to the value, or null when removed or generation mismatched.
        pub fn getConst(ref: ResourceRef) ?*const T {
            const id = check(ref) orelse return null;
            return &slots.items[id].?;
        }

        /// Checks whether a reference points at a live slot.
        /// Parameters:
        /// - ref: reference to inspect.
        /// Returns: true when the slot is occupied with a matching generation.
        pub fn isAlive(ref: ResourceRef) bool {
            return check(ref) != null;
        }

        /// Frees a slot and returns the value that was stored there.
        /// Only releases bookkeeping: destroying the underlying resource (if any)
        /// is a separate caller-owned step performed on the returned value.
        /// Parameters:
        /// - alloc: allocator for the free list.
        /// - ref: reference to remove.
        /// Returns: stored value, or null when the reference is stale or empty.
        pub fn remove(alloc: std.mem.Allocator, ref: ResourceRef) !?T {
            const id = check(ref) orelse return null;
            const value = slots.items[id].?;
            slots.items[id] = null;
            bitClear(occupied.items, id);
            generations.items[id] +%= 1;
            live_count -= 1;
            try free_ids.append(alloc, @intCast(id));
            return value;
        }

        /// Finds the next occupied slot after the given reference.
        /// Intended for `while` iteration over all live elements:
        /// `var cur: ?ResourceRef = null; while (Pool.nextElement(cur)) |r| { cur = r; ... }`.
        /// Parameters:
        /// - after: reference to start after, or null to start from the beginning.
        /// Returns: reference to the next live slot (with its current generation), or null at the end.
        pub fn nextElement(after: ?ResourceRef) ?ResourceRef {
            var idx: usize = if (after) |r| @as(usize, r.id) + 1 else 0;
            const n: usize = slots.items.len;
            while (idx < n) {
                const wi = idx / 64;
                const shift: u6 = @intCast(idx % 64);
                const word = occupied.items[wi] >> shift;
                if (word != 0) {
                    const found: usize = idx + @ctz(word);
                    if (found < n) return .{ .id = @intCast(found), .gen = generations.items[found] };
                    return null;
                }
                idx = (wi + 1) * 64;
            }
            return null;
        }

        /// Returns the number of currently occupied slots.
        /// Returns: live slot count in O(1).
        pub fn liveCount() usize {
            return live_count;
        }

        /// Returns the total slot capacity (live + free).
        /// Returns: length of the slot array.
        pub fn capacity() usize {
            return slots.items.len;
        }

        /// Frees pool bookkeeping arrays. Stored values are NOT touched:
        /// the pool only tracks resources, it never owns them.
        /// Parameters:
        /// - alloc: allocator that was used for pool operations.
        pub fn deinit(alloc: std.mem.Allocator) void {
            slots.deinit(alloc);
            slots = .empty;
            free_ids.deinit(alloc);
            free_ids = .empty;
            occupied.deinit(alloc);
            occupied = .empty;
            generations.deinit(alloc);
            generations = .empty;
            live_count = 0;
        }
    };
}

test "pool add/get/remove with id reuse and generation bump" {
    const R = struct { v: i32 };
    const P = SlotPool(R);
    const alloc = std.testing.allocator;
    defer P.deinit(alloc);

    const r0 = try P.add(alloc, .{ .v = 10 });
    const r1 = try P.add(alloc, .{ .v = 20 });
    try std.testing.expectEqual(@as(u32, 0), r0.id);
    try std.testing.expectEqual(@as(u32, 1), r1.id);
    try std.testing.expectEqual(@as(usize, 2), P.liveCount());
    try std.testing.expectEqual(@as(i32, 10), P.get(r0).?.v);

    const taken = (try P.remove(alloc, r0)).?;
    try std.testing.expectEqual(@as(i32, 10), taken.v);
    try std.testing.expect(P.get(r0) == null); // stale: bit cleared
    try std.testing.expect(!P.isAlive(r0));
    try std.testing.expectEqual(@as(usize, 1), P.liveCount());

    const r2 = try P.add(alloc, .{ .v = 30 });
    try std.testing.expectEqual(@as(u32, 0), r2.id); // id reused
    try std.testing.expect(r2.gen == r0.gen +% 1); // generation bumped
    try std.testing.expect(P.get(r0) == null); // old ref stays dead (gen mismatch)
    try std.testing.expectEqual(@as(i32, 30), P.get(r2).?.v);
}

test "pool double remove and unknown refs" {
    const R = struct { v: u8 };
    const P = SlotPool(R);
    const alloc = std.testing.allocator;
    defer P.deinit(alloc);

    const r = try P.add(alloc, .{ .v = 1 });
    _ = try P.remove(alloc, r);
    try std.testing.expect(try P.remove(alloc, r) == null); // second remove: null
    try std.testing.expect(P.get(.{ .id = 99, .gen = 0 }) == null); // out of bounds
    try std.testing.expect(P.get(ref_mod.NO_REF) == null); // null sentinel
}

test "pool nextElement skips holes" {
    const R = struct { v: u32 };
    const P = SlotPool(R);
    const alloc = std.testing.allocator;
    defer P.deinit(alloc);

    var refs: [5]ResourceRef = undefined;
    for (&refs, 0..) |*slot, i| slot.* = try P.add(alloc, .{ .v = @intCast(i) });
    _ = try P.remove(alloc, refs[1]);
    _ = try P.remove(alloc, refs[3]);

    var seen: [3]u32 = undefined;
    var n: usize = 0;
    var cur: ?ResourceRef = null;
    while (P.nextElement(cur)) |r| {
        cur = r;
        seen[n] = P.get(r).?.v;
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 0, 2, 4 }, seen[0..n]);
    try std.testing.expect(P.nextElement(cur) == null);
    // resume after a middle element
    const after = P.nextElement(refs[0]).?;
    try std.testing.expectEqual(refs[2].id, after.id);
}

test "pool stores pointer resources directly" {
    const P = SlotPool(*u32);
    const alloc = std.testing.allocator;
    defer P.deinit(alloc);

    var x: u32 = 42;
    const r = try P.add(alloc, &x);
    try std.testing.expectEqual(@as(u32, 42), P.get(r).?.*.*);
}
