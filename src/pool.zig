/// Standard library import.
const std = @import("std");
/// Resource reference type import.
const resource_mod = @import("resource.zig");
/// Hierarchical bit utilities, occupancy backend.
const bit_tree = @import("bit_tree");

/// Flat occupancy bitset, one bit per slot.
const Occupancy = bit_tree.Bitset(.u64);

/// Creates a global per-type resource store with stable ids.
///
/// Each instantiation `ResourceStore(T, tag)` owns its own static storage, so
/// repeating the same `(T, tag)` from any point of the program yields the same
/// store, while different `tag`s give fully isolated instances for the same `T`
/// (e.g. `ResourceStore(Mesh, .main)` vs `ResourceStore(Mesh, .ui)`).
/// The store only tracks resources: it never destroys the stored values.
///
/// Storage per store:
/// - `slots` — resources, index == stable id;
/// - `free_ids` — ids of empty slots reused by the next `add`;
/// - `occupied` — occupancy bitmap (`bit_tree.Bitset`), one bit per slot;
/// - `generations` — one byte per slot, bumped (`+%= 1`) on every `remove`.
///
/// Parameters:
/// - `T`: resource record type stored in the store (e.g. an abstraction struct
///   or a direct pointer such as `*Texture` for non-generic types).
/// - `tag`: enum literal isolating instances (`@EnumLiteral` style, e.g.
///   `.default`, `.main`). Must be an enum literal.
/// Returns: store namespace with static storage and operations.
pub fn ResourceStore(comptime T: type, comptime tag: anytype) type {
    comptime {
        if (@typeInfo(@TypeOf(tag)) != .enum_literal) {
            @compileError("ResourceStore tag must be an enum literal, e.g. .default");
        }
    }
    return struct {
        /// Store tag isolating instances for the same `T`.
        pub const tag_value = tag;
        /// Stored record type.
        pub const resource_type = T;
        /// ECS-compatible reference to a pooled resource.
        /// Re-exported here so users take it from the store
        /// (`const res: MeshStore.Resource = ...`) instead of importing it directly.
        pub const Resource = resource_mod.Resource(T, tag);

        /// Slot storage, index == stable id. `null` means the slot is free.
        var slots: std.ArrayListUnmanaged(?T) = .empty;
        /// Ids of free slots, reused by the next `add`.
        var free_ids: std.ArrayListUnmanaged(u32) = .empty;
        /// Occupancy bitmap, one bit per slot. `bits_count` mirrors `slots.len`.
        var occupied: Occupancy = .{};
        /// Generation byte per slot, bumped on every `remove`.
        var generations: std.ArrayListUnmanaged(u8) = .empty;

        /// Validates a reference against bounds, occupancy and generation.
        /// Parameters:
        /// - ref: reference to validate.
        /// Returns: slot index, or null when the reference is stale or empty.
        fn check(ref: Resource) ?usize {
            if (ref.isNull()) return null;
            const id: usize = ref.id;
            if (id >= slots.items.len) return null;
            if (id >= occupied.bits_count) return null;
            if (occupied.getBit(@intCast(id)) == .inactive) return null;
            if (generations.items[id] != ref.gen) return null;
            return id;
        }

        /// Stores a value and returns a stable reference to it.
        /// Reuses an id from the free list when possible, otherwise appends.
        /// Parameters:
        /// - alloc: allocator for slot storage.
        /// - value: resource record to store.
        /// Returns: reference with the slot id and its current generation.
        pub fn add(alloc: std.mem.Allocator, value: T) !Resource {
            if (free_ids.pop()) |reuse_id| {
                slots.items[reuse_id] = value;
                occupied.setBit(reuse_id, .active);
                return .{ .id = @intCast(reuse_id), .gen = generations.items[reuse_id] };
            }
            const id: usize = slots.items.len;
            try slots.append(alloc, value);
            try generations.append(alloc, 0);
            try occupied.resize(alloc, @intCast(slots.items.len), .inactive);
            occupied.setBit(@intCast(id), .active);
            return .{ .id = @intCast(id), .gen = 0 };
        }

        /// Resolves a reference to the stored value.
        /// Parameters:
        /// - ref: reference to resolve.
        /// Returns: pointer to the value, or null when removed or generation mismatched.
        pub fn get(ref: Resource) ?*T {
            const id = check(ref) orelse return null;
            return &slots.items[id].?;
        }

        /// Checks whether a reference points at a live slot.
        /// Parameters:
        /// - ref: reference to inspect.
        /// Returns: true when the slot is occupied with a matching generation.
        pub fn isAlive(ref: Resource) bool {
            return check(ref) != null;
        }

        /// Frees a slot and returns the value that was stored there.
        /// Only releases bookkeeping: destroying the underlying resource (if any)
        /// is a separate caller-owned step performed on the returned value.
        /// Parameters:
        /// - alloc: allocator for the free list.
        /// - ref: reference to remove.
        /// Returns: stored value, or null when the reference is stale or empty.
        pub fn remove(alloc: std.mem.Allocator, ref: Resource) !?T {
            const id = check(ref) orelse return null;
            const value = slots.items[id].?;
            slots.items[id] = null;
            occupied.setBit(@intCast(id), .inactive);
            generations.items[id] +%= 1;
            try free_ids.append(alloc, @intCast(id));
            return value;
        }

        /// Active-only iterator over live slots, thin wrapper over the
        /// `bit_tree` bitset iterator with the inactive callback removed.
        /// The single callback fires per occupied bit with a ready `Resource`
        /// (`get()` resolves the value); iterating inactive bits makes no
        /// sense here and would break pool invariants, so it is not exposed.
        ///
        /// Idiom (same shape as `t_ecs` queries):
        /// `const It = Pool.Iterator(*Ctx, Ctx.onItem, .forward);`
        /// `try It.iterateAll(&ctx, null, null);`
        pub fn Iterator(
            comptime Context: type,
            comptime on_item: fn (context: Context, ref: Resource) callconv(.@"inline") anyerror!bool,
            comptime direction: bit_tree.Direction,
        ) type {
            return struct {
                /// Carrier for the outer caller context through the bitset walk.
                const InnerCtx = struct {
                    outer: Context,
                };

                /// Maps one active bit id to its live reference and forwards it.
                inline fn shim(ctx: InnerCtx, bit_id: u32) anyerror!bool {
                    const idx: usize = @intCast(bit_id);
                    const ref: Resource = .{ .id = @intCast(bit_id), .gen = generations.items[idx] };
                    return try on_item(ctx.outer, ref);
                }

                /// Underlying bitset iterator: active only, inactive arm is null.
                const Inner = Occupancy.Iterator(InnerCtx, shim, null, direction);

                /// Runs the walk over an optional bit range.
                /// Returns false on early callback exit (`on_item` returned false);
                /// a `try` inside `on_item` aborts the walk with that error.
                pub fn iterateAll(ctx: Context, start_bit: ?u32, end_bit: ?u32) anyerror!bool {
                    return Inner.iterateAll(.{ .bitset = &occupied, .context = .{ .outer = ctx } }, start_bit, end_bit);
                }
            };
        }

        /// Returns the number of currently occupied slots.
        /// Returns: live slot count in O(1) via the bitset active counter.
        pub fn liveCount() usize {
            return @intCast(occupied.active_bits_counter);
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
            occupied = .{};
            generations.deinit(alloc);
            generations = .empty;
        }

        /// Destroys every live item through a caller callback, in forward order.
        /// Builds a forward `Iterator` with an `Allocator` context under the
        /// hood and immediately runs it over the full range, so callers pass
        /// only the per-item destructor. The reference resolves via `get()`.
        /// Pool bookkeeping is left intact: call `deinit` afterwards to free it.
        /// The callback must not `add`/`remove` slots: mutating occupancy
        /// mid-walk would corrupt the iteration.
        /// Parameters:
        /// - alloc: context forwarded to every callback invocation.
        /// - on_item_deinit: per-live-slot destructor, receives allocator and ref.
        pub fn deinitItems(
            alloc: std.mem.Allocator,
            comptime on_item_deinit: fn (item_alloc: std.mem.Allocator, ref: Resource) callconv(.@"inline") anyerror!void,
        ) !void {
            const Adapter = struct {
                inline fn onItem(a: std.mem.Allocator, ref: Resource) anyerror!bool {
                    try on_item_deinit(a, ref);
                    return true;
                }
            };
            const It = Iterator(std.mem.Allocator, Adapter.onItem, .forward);
            _ = try It.iterateAll(alloc, null, null);
        }

        /// Destroys every live item through its own destructor, in forward order.
        /// Default callback over `deinitItems`: prefers `deinit(allocator)` and
        /// falls back to `destroy(allocator)`. For pointer records (e.g.
        /// `*Texture`, `*const Texture`) the pointee type is inspected instead.
        /// Accepted `self` shapes (for both `deinit` and `destroy`), independent
        /// of whether the pool stores `T`, `*T` or `*const T`:
        /// `T` (by value), `*T`, `*const T`, `*anyopaque`, `*const anyopaque`.
        /// A `*const T` pool storing a const pointer is `@constCast`-ed back to
        /// mutable when the destructor requires a mutable receiver
        /// (`*T` / `*anyopaque`); a value receiver gets `ptr.*` (a copy).
        /// The expected shape is `pub fn deinit(self, std.mem.Allocator) void`
        /// (same for `destroy`); a type-erased receiver is cast back inside with
        /// `@ptrCast(@alignCast(self))`, as is an `!void` return (propagated).
        /// If neither declaration exists, compilation fails with a
        /// hint to use `deinitItems` with an explicit callback instead.
        /// Pool bookkeeping is left intact: call `deinit` afterwards to free it.
        /// The destructor must not `add`/`remove` slots: mutating occupancy
        /// mid-walk would corrupt the iteration.
        /// Parameters:
        /// - alloc: allocator forwarded to every destructor invocation.
        pub fn deinitItemsAuto(alloc: std.mem.Allocator) !void {
            const Host = switch (@typeInfo(T)) {
                .pointer => |p| p.child,
                else => T,
            };
            const has_deinit = switch (@typeInfo(Host)) {
                .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(Host, "deinit"),
                else => false,
            };
            const has_destroy = switch (@typeInfo(Host)) {
                .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(Host, "destroy"),
                else => false,
            };
            if (!has_deinit and !has_destroy) {
                @compileError("ResourceStore(" ++ @typeName(T) ++ "): deinitItemsAuto requires `pub fn deinit(allocator)` or `pub fn destroy(allocator)` on the pooled type (or its pointee for pointer types); use deinitItems(alloc, customCallback) instead.");
            }
            // Tolerates both `void` and `!void` destructors: the result is only
            // `try`-ed when it actually is an error union.
            // Qualified calls (`Host.deinit(recv, a)`) are used instead of method
            // syntax on purpose: a `self: *anyopaque` destructor is not a member
            // function, so `recv.deinit(a)` would not resolve, while the
            // qualified form accepts both `*Self` and `*anyopaque` receivers.
            const Auto = struct {
                /// Forwards a `*Host` / `*const Host` pointer to whatever `self`
                /// shape the destructor declares: by value (`ptr.*`), mutable or
                /// const concrete pointer (direct, `@constCast` when a mutable
                /// receiver meets a const pointer, e.g. from a `*const T` pool),
                /// or type-erased (`*anyopaque` / `*const anyopaque`, same const
                /// rule, implicit coercion handles the type erasure).
                inline fn invoke(comptime dtor: anytype, host_ptr: anytype, a: std.mem.Allocator) anyerror!void {
                    const SelfParam = @typeInfo(@TypeOf(dtor)).@"fn".params[0].type orelse
                        @compileError("destructor first param must have an explicit type");
                    if (SelfParam == Host) {
                        const r = dtor(host_ptr.*, a);
                        if (comptime @typeInfo(@TypeOf(r)) == .error_union) try r;
                    } else {
                        const sp_info = @typeInfo(SelfParam);
                        if (sp_info != .pointer) {
                            @compileError("destructor self must be T, *T, *const T, *anyopaque or *const anyopaque, got " ++ @typeName(SelfParam));
                        }
                        const sp = sp_info.pointer;
                        const is_host = (sp.child == Host);
                        const is_erased = (sp.child == anyopaque);
                        if (!is_host and !is_erased) {
                            @compileError("destructor self must be T, *T, *const T, *anyopaque or *const anyopaque, got " ++ @typeName(SelfParam));
                        }
                        if (sp.is_const) {
                            // `*const T` / `*const anyopaque`: mutable and const
                            // sources both coerce (incl. concrete -> opaque).
                            const r = dtor(host_ptr, a);
                            if (comptime @typeInfo(@TypeOf(r)) == .error_union) try r;
                        } else {
                            // Mutable receiver: drop const from a `*const T`
                            // pool pointer when required.
                            if (comptime @typeInfo(@TypeOf(host_ptr)).pointer.is_const) {
                                const mut = @constCast(host_ptr);
                                const r = dtor(mut, a);
                                if (comptime @typeInfo(@TypeOf(r)) == .error_union) try r;
                            } else {
                                const r = dtor(host_ptr, a);
                                if (comptime @typeInfo(@TypeOf(r)) == .error_union) try r;
                            }
                        }
                    }
                }

                inline fn run(a: std.mem.Allocator, ref: Resource) anyerror!void {
                    if (comptime @typeInfo(T) == .pointer) {
                        const stored: T = get(ref).?.*;
                        if (comptime has_deinit) {
                            try invoke(Host.deinit, stored, a);
                        } else {
                            try invoke(Host.destroy, stored, a);
                        }
                    } else {
                        const item = get(ref).?;
                        if (comptime has_deinit) {
                            try invoke(Host.deinit, item, a);
                        } else {
                            try invoke(Host.destroy, item, a);
                        }
                    }
                }
            };
            return deinitItems(alloc, Auto.run);
        }
    };
}

test "pool add/get/remove with id reuse and generation bump" {
    const R = struct { v: i32 };
    const P = ResourceStore(R, .default);
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
    const P = ResourceStore(R, .default);
    const alloc = std.testing.allocator;
    defer P.deinit(alloc);

    const r = try P.add(alloc, .{ .v = 1 });
    _ = try P.remove(alloc, r);
    try std.testing.expect(try P.remove(alloc, r) == null); // second remove: null
    try std.testing.expect(P.get(.{ .id = 99, .gen = 0 }) == null); // out of bounds
    try std.testing.expect(P.get(P.Resource.NULL) == null); // null sentinel
}

test "pool iterator visits live refs in order" {
    const R = struct { v: u32 };
    const P = ResourceStore(R, .default);
    const alloc = std.testing.allocator;
    defer P.deinit(alloc);

    var refs: [5]P.Resource = undefined;
    for (&refs, 0..) |*slot, i| slot.* = try P.add(alloc, .{ .v = @intCast(i) });
    _ = try P.remove(alloc, refs[1]);
    _ = try P.remove(alloc, refs[3]);

    const Collect = struct {
        ids: [3]u32 = undefined,
        n: usize = 0,
        inline fn push(ctx: *@This(), ref: P.Resource) anyerror!bool {
            try std.testing.expect(P.isAlive(ref));
            ctx.ids[ctx.n] = ref.id;
            // ref resolves through get(), no IterationResult needed
            try std.testing.expectEqual(ref.id, P.get(ref).?.v);
            ctx.n += 1;
            return true;
        }
    };
    var c = Collect{};
    const It = P.Iterator(*Collect, Collect.push, .forward);
    try std.testing.expect(try It.iterateAll(&c, null, null));
    try std.testing.expectEqual(@as(usize, 3), c.n);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 0, 2, 4 }, c.ids[0..c.n]);
}

test "pool iterator corner cases" {
    const R = struct { v: usize };
    const P = ResourceStore(R, .default);
    const alloc = std.testing.allocator;
    defer P.deinit(alloc);

    const Collect = struct {
        ids: [8]u32 = undefined,
        n: usize = 0,
        inline fn push(ctx: *@This(), ref: P.Resource) anyerror!bool {
            ctx.ids[ctx.n] = ref.id;
            ctx.n += 1;
            return true;
        }
    };

    // empty pool: no visits, completed walk
    {
        var c = Collect{};
        const It = P.Iterator(*Collect, Collect.push, .forward);
        try std.testing.expect(try It.iterateAll(&c, null, null));
        try std.testing.expectEqual(@as(usize, 0), c.n);
    }

    // single element, forward and backward agree
    const only = try P.add(alloc, .{ .v = 100 });
    {
        var c = Collect{};
        const It = P.Iterator(*Collect, Collect.push, .forward);
        try std.testing.expect(try It.iterateAll(&c, null, null));
        try std.testing.expectEqual(@as(usize, 1), c.n);
        try std.testing.expectEqual(only.id, c.ids[0]);
        try std.testing.expectEqual(@as(usize, 100), P.get(.{ .id = @intCast(c.ids[0]), .gen = only.gen }).?.v);
    }
    {
        var c = Collect{};
        const It = P.Iterator(*Collect, Collect.push, .backward);
        try std.testing.expect(try It.iterateAll(&c, null, null));
        try std.testing.expectEqual(@as(usize, 1), c.n);
        try std.testing.expectEqual(only.id, c.ids[0]);
    }
    _ = try P.remove(alloc, only);
    {
        var c = Collect{};
        const It = P.Iterator(*Collect, Collect.push, .forward);
        try std.testing.expect(try It.iterateAll(&c, null, null));
        try std.testing.expectEqual(@as(usize, 0), c.n);
    }

    // holes at the start and at the end: only b stays live
    const a = try P.add(alloc, .{ .v = 1 });
    const b = try P.add(alloc, .{ .v = 2 });
    const c_ref = try P.add(alloc, .{ .v = 3 });
    _ = try P.remove(alloc, a);
    _ = try P.remove(alloc, c_ref);
    {
        var c = Collect{};
        const It = P.Iterator(*Collect, Collect.push, .forward);
        try std.testing.expect(try It.iterateAll(&c, null, null));
        try std.testing.expectEqual(@as(usize, 1), c.n);
        try std.testing.expectEqual(b.id, c.ids[0]);
    }
    // ranged walk that excludes the live slot visits nothing
    {
        var c = Collect{};
        const It = P.Iterator(*Collect, Collect.push, .forward);
        try std.testing.expect(try It.iterateAll(&c, 0, b.id));
        try std.testing.expectEqual(@as(usize, 0), c.n);
    }
    // resume via bit range past the hole lands on b
    {
        var c = Collect{};
        const It = P.Iterator(*Collect, Collect.push, .forward);
        try std.testing.expect(try It.iterateAll(&c, a.id, null));
        try std.testing.expectEqual(@as(usize, 1), c.n);
        try std.testing.expectEqual(b.id, c.ids[0]);
    }

    // early exit: first callback returns false
    {
        const Stop = struct {
            n: usize = 0,
            inline fn push(ctx: *@This(), ref: P.Resource) anyerror!bool {
                _ = ref;
                ctx.n += 1;
                return false;
            }
        };
        var s = Stop{};
        const It = P.Iterator(*Stop, Stop.push, .forward);
        try std.testing.expect(!try It.iterateAll(&s, null, null));
        try std.testing.expectEqual(@as(usize, 1), s.n);
    }

    // error propagation from the callback
    {
        const Fail = struct {
            inline fn push(ctx: *@This(), ref: P.Resource) anyerror!bool {
                _ = ctx;
                _ = ref;
                return error.Boom;
            }
        };
        var f = Fail{};
        const It = P.Iterator(*Fail, Fail.push, .forward);
        try std.testing.expectError(error.Boom, It.iterateAll(&f, null, null));
    }
}

test "pool iterator multi-word bitmap" {
    const R = struct { v: usize };
    const P = ResourceStore(R, .default);
    const alloc = std.testing.allocator;
    defer P.deinit(alloc);

    const N = 200;
    var refs: [N]P.Resource = undefined;
    for (&refs, 0..) |*slot, i| slot.* = try P.add(alloc, .{ .v = i });
    var removed: usize = 0;
    for (refs, 0..) |r, i| {
        if (i % 3 == 0 or i == 63 or i == 64 or i == 65 or i == 127 or i == 128) {
            _ = try P.remove(alloc, r);
            removed += 1;
        }
    }

    const Collect = struct {
        n: usize = 0,
        prev: ?u32 = null,
        inline fn push(ctx: *@This(), ref: P.Resource) anyerror!bool {
            if (ctx.prev) |p| try std.testing.expect(ref.id > p);
            try std.testing.expect(P.isAlive(ref));
            try std.testing.expectEqual(@as(usize, ref.id), P.get(ref).?.v);
            ctx.prev = ref.id;
            ctx.n += 1;
            return true;
        }
    };
    var c = Collect{};
    const It = P.Iterator(*Collect, Collect.push, .forward);
    try std.testing.expect(try It.iterateAll(&c, null, null));
    try std.testing.expectEqual(N - removed, c.n);
    try std.testing.expectEqual(N - removed, P.liveCount());

    // backward walk visits the same count in reverse
    const Rev = struct {
        n: usize = 0,
        prev: ?u32 = null,
        inline fn push(ctx: *@This(), ref: P.Resource) anyerror!bool {
            if (ctx.prev) |p| try std.testing.expect(ref.id < p);
            ctx.prev = ref.id;
            ctx.n += 1;
            return true;
        }
    };
    var rev = Rev{};
    const RIt = P.Iterator(*Rev, Rev.push, .backward);
    try std.testing.expect(try RIt.iterateAll(&rev, null, null));
    try std.testing.expectEqual(N - removed, rev.n);

    // resume across a 64-bit word boundary via bit range: 63..66 are holes, next live is 67
    {
        const Head = struct {
            first: ?u32 = null,
            n: usize = 0,
            inline fn push(ctx: *@This(), ref: P.Resource) anyerror!bool {
                if (ctx.first == null) ctx.first = ref.id;
                ctx.n += 1;
                return true;
            }
        };
        var head = Head{};
        const HIt = P.Iterator(*Head, Head.push, .forward);
        try std.testing.expect(try HIt.iterateAll(&head, 63, null));
        try std.testing.expectEqual(@as(?u32, 67), head.first);
    }
}

test "pool stores pointer resources directly" {
    const P = ResourceStore(*u32, .default);
    const alloc = std.testing.allocator;
    defer P.deinit(alloc);

    var x: u32 = 42;
    const r = try P.add(alloc, &x);
    try std.testing.expectEqual(@as(u32, 42), P.get(r).?.*.*);
}

test "pool deinitItems visits every live ref with allocator context" {
    const R = struct { v: u32, owned: []u8 };
    const P = ResourceStore(R, .default);
    const alloc = std.testing.allocator;
    defer P.deinit(alloc);

    // empty pool: callback never fires, no error
    {
        const Never = struct {
            inline fn run(a: std.mem.Allocator, ref: P.Resource) anyerror!void {
                _ = a;
                _ = ref;
                unreachable;
            }
        };
        try P.deinitItems(alloc, Never.run);
    }

    var refs: [5]P.Resource = undefined;
    for (&refs, 0..) |*slot, i| {
        const owned = try alloc.dupe(u8, &[_]u8{@intCast(i)});
        slot.* = try P.add(alloc, .{ .v = @intCast(i), .owned = owned });
    }
    // free one slot manually so deinitItems must skip the hole
    {
        const taken = (try P.remove(alloc, refs[0])).?;
        alloc.free(taken.owned);
    }
    try std.testing.expectEqual(@as(usize, 4), P.liveCount());

    const FreeAll = struct {
        inline fn run(a: std.mem.Allocator, ref: P.Resource) anyerror!void {
            // allocator context arrives intact, ref resolves through get()
            try std.testing.expect(P.isAlive(ref));
            const item = P.get(ref).?;
            a.free(item.owned);
            // mark freed without touching pool structure (no add/remove here)
            item.owned = &.{};
        }
    };
    try P.deinitItems(alloc, FreeAll.run);
    // bookkeeping untouched: slots still tracked, values now hold empty slices
    try std.testing.expectEqual(@as(usize, 4), P.liveCount());
    {
        const Counter = struct {
            inline fn push(ctx: *usize, ref: P.Resource) anyerror!bool {
                _ = ref;
                ctx.* += 1;
                return true;
            }
        };
        var n: usize = 0;
        const It = P.Iterator(*usize, Counter.push, .forward);
        _ = try It.iterateAll(&n, null, null);
        try std.testing.expectEqual(@as(usize, 4), n);
    }
}

test "pool deinitItems propagates callback errors" {
    const R = struct { v: u32 };
    const P = ResourceStore(R, .default);
    const alloc = std.testing.allocator;
    defer P.deinit(alloc);

    _ = try P.add(alloc, .{ .v = 1 });
    _ = try P.add(alloc, .{ .v = 2 });
    const Fail = struct {
        inline fn run(a: std.mem.Allocator, ref: P.Resource) anyerror!void {
            _ = a;
            _ = ref;
            return error.Boom;
        }
    };
    try std.testing.expectError(error.Boom, P.deinitItems(alloc, Fail.run));
}

test "pool deinitItemsAuto prefers deinit over destroy" {
    const R = struct {
        owned: []u8,
        var calls_deinit: usize = 0;
        var calls_destroy: usize = 0;
        pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
            alloc.free(self.owned);
            self.owned = &.{};
            calls_deinit += 1;
        }
        pub fn destroy(self: *@This(), alloc: std.mem.Allocator) void {
            _ = self;
            _ = alloc;
            calls_destroy += 1;
        }
    };
    const P = ResourceStore(R, .default);
    const alloc = std.testing.allocator;
    defer P.deinit(alloc);

    var refs: [3]P.Resource = undefined;
    for (&refs, 0..) |*slot, i| {
        const owned = try alloc.dupe(u8, &[_]u8{@intCast(i)});
        slot.* = try P.add(alloc, .{ .owned = owned });
    }
    // free one slot manually so the auto walk must skip the hole
    {
        const taken = (try P.remove(alloc, refs[0])).?;
        alloc.free(taken.owned);
    }

    try P.deinitItemsAuto(alloc);
    try std.testing.expectEqual(@as(usize, 2), R.calls_deinit);
    try std.testing.expectEqual(@as(usize, 0), R.calls_destroy);
    // bookkeeping untouched: slots still tracked
    try std.testing.expectEqual(@as(usize, 2), P.liveCount());
}

test "pool deinitItemsAuto falls back to destroy" {
    const D = struct {
        owned: []u8,
        var calls: usize = 0;
        // fallible form: exercises the `!void` destructor path
        pub fn destroy(self: *@This(), alloc: std.mem.Allocator) !void {
            alloc.free(self.owned);
            self.owned = &.{};
            calls += 1;
        }
    };
    const P = ResourceStore(D, .default);
    const alloc = std.testing.allocator;
    defer P.deinit(alloc);

    for (0..2) |i| {
        const owned = try alloc.dupe(u8, &[_]u8{@intCast(i)});
        _ = try P.add(alloc, .{ .owned = owned });
    }

    try P.deinitItemsAuto(alloc);
    try std.testing.expectEqual(@as(usize, 2), D.calls);
    try std.testing.expectEqual(@as(usize, 2), P.liveCount());
}

test "pool deinitItemsAuto propagates destructor errors" {
    const F = struct {
        v: u32,
        pub fn deinit(self: *@This(), alloc: std.mem.Allocator) !void {
            _ = self;
            _ = alloc;
            return error.Boom;
        }
    };
    const P = ResourceStore(F, .default);
    const alloc = std.testing.allocator;
    defer P.deinit(alloc);

    _ = try P.add(alloc, .{ .v = 1 });
    try std.testing.expectError(error.Boom, P.deinitItemsAuto(alloc));
}

test "pool deinitItemsAuto supports anyopaque self destructor" {
    const G = struct {
        owned: []u8,
        var calls: usize = 0;
        // type-erased self: cast back to the concrete type inside
        pub fn deinit(self: *anyopaque, alloc: std.mem.Allocator) void {
            const this: *@This() = @ptrCast(@alignCast(self));
            alloc.free(this.owned);
            this.owned = &.{};
            calls += 1;
        }
    };
    const P = ResourceStore(G, .default);
    const alloc = std.testing.allocator;
    defer P.deinit(alloc);

    for (0..2) |i| {
        const owned = try alloc.dupe(u8, &[_]u8{@intCast(i)});
        _ = try P.add(alloc, .{ .owned = owned });
    }
    try P.deinitItemsAuto(alloc);
    try std.testing.expectEqual(@as(usize, 2), G.calls);
    try std.testing.expectEqual(@as(usize, 2), P.liveCount());
}

test "pool deinitItemsAuto supports anyopaque self destroy on pointee" {
    const H = struct {
        owned: []u8,
        var calls: usize = 0;
        // fallible type-erased destroy on the pointee behind a `*H` record
        pub fn destroy(self: *anyopaque, alloc: std.mem.Allocator) !void {
            const this: *@This() = @ptrCast(@alignCast(self));
            alloc.free(this.owned);
            this.owned = &.{};
            calls += 1;
        }
    };
    const P = ResourceStore(*H, .default);
    const alloc = std.testing.allocator;
    defer P.deinit(alloc);

    var h1 = H{ .owned = try alloc.dupe(u8, &[_]u8{1}) };
    var h2 = H{ .owned = try alloc.dupe(u8, &[_]u8{2}) };
    _ = try P.add(alloc, &h1);
    _ = try P.add(alloc, &h2);

    try P.deinitItemsAuto(alloc);
    try std.testing.expectEqual(@as(usize, 2), H.calls);
    try std.testing.expectEqual(@as(usize, 0), h1.owned.len);
    try std.testing.expectEqual(@as(usize, 0), h2.owned.len);
}

test "pool deinitItemsAuto works for pointer records via pointee" {
    const Tex = struct {
        owned: []u8,
        var calls: usize = 0;
        pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
            alloc.free(self.owned);
            self.owned = &.{};
            calls += 1;
        }
    };
    const P = ResourceStore(*Tex, .default);
    const alloc = std.testing.allocator;
    defer P.deinit(alloc);

    var t1 = Tex{ .owned = try alloc.dupe(u8, &[_]u8{1}) };
    var t2 = Tex{ .owned = try alloc.dupe(u8, &[_]u8{2}) };
    _ = try P.add(alloc, &t1);
    _ = try P.add(alloc, &t2);

    try P.deinitItemsAuto(alloc);
    try std.testing.expectEqual(@as(usize, 2), Tex.calls);
    try std.testing.expectEqual(@as(usize, 0), t1.owned.len);
    try std.testing.expectEqual(@as(usize, 0), t2.owned.len);
}

test "pool deinitItemsAuto all self x pool x method combos" {
    const alloc = std.testing.allocator;

    // ---- deinit, self by value (T) ----
    {
        const H = struct {
            owned: []u8,
            var calls: usize = 0;
            pub fn deinit(self: @This(), a: std.mem.Allocator) void {
                a.free(self.owned);
                calls += 1;
            }
        };
        {
            const P = ResourceStore(H, .default);
            defer P.deinit(alloc);
            H.calls = 0;
            _ = try P.add(alloc, .{ .owned = try alloc.dupe(u8, &[_]u8{1}) });
            _ = try P.add(alloc, .{ .owned = try alloc.dupe(u8, &[_]u8{2}) });
            try P.deinitItemsAuto(alloc);
            try std.testing.expectEqual(@as(usize, 2), H.calls);
        }
        {
            const P = ResourceStore(*H, .default);
            defer P.deinit(alloc);
            H.calls = 0;
            var h1 = H{ .owned = try alloc.dupe(u8, &[_]u8{1}) };
            var h2 = H{ .owned = try alloc.dupe(u8, &[_]u8{2}) };
            _ = try P.add(alloc, &h1);
            _ = try P.add(alloc, &h2);
            try P.deinitItemsAuto(alloc);
            try std.testing.expectEqual(@as(usize, 2), H.calls);
        }
        {
            const P = ResourceStore(*const H, .default);
            defer P.deinit(alloc);
            H.calls = 0;
            var h1 = H{ .owned = try alloc.dupe(u8, &[_]u8{1}) };
            var h2 = H{ .owned = try alloc.dupe(u8, &[_]u8{2}) };
            _ = try P.add(alloc, &h1);
            _ = try P.add(alloc, &h2);
            try P.deinitItemsAuto(alloc);
            try std.testing.expectEqual(@as(usize, 2), H.calls);
        }
    }

    // ---- deinit, self *T ----
    {
        const H = struct {
            owned: []u8,
            var calls: usize = 0;
            pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
                a.free(self.owned);
                self.owned = &.{};
                calls += 1;
            }
        };
        {
            const P = ResourceStore(H, .default);
            defer P.deinit(alloc);
            H.calls = 0;
            const r1 = try P.add(alloc, .{ .owned = try alloc.dupe(u8, &[_]u8{1}) });
            const r2 = try P.add(alloc, .{ .owned = try alloc.dupe(u8, &[_]u8{2}) });
            try P.deinitItemsAuto(alloc);
            try std.testing.expectEqual(@as(usize, 2), H.calls);
            try std.testing.expectEqual(@as(usize, 0), P.get(r1).?.owned.len);
            try std.testing.expectEqual(@as(usize, 0), P.get(r2).?.owned.len);
        }
        {
            const P = ResourceStore(*H, .default);
            defer P.deinit(alloc);
            H.calls = 0;
            var h1 = H{ .owned = try alloc.dupe(u8, &[_]u8{1}) };
            var h2 = H{ .owned = try alloc.dupe(u8, &[_]u8{2}) };
            _ = try P.add(alloc, &h1);
            _ = try P.add(alloc, &h2);
            try P.deinitItemsAuto(alloc);
            try std.testing.expectEqual(@as(usize, 2), H.calls);
            try std.testing.expectEqual(@as(usize, 0), h1.owned.len);
            try std.testing.expectEqual(@as(usize, 0), h2.owned.len);
        }
        {
            const P = ResourceStore(*const H, .default);
            defer P.deinit(alloc);
            H.calls = 0;
            var h1 = H{ .owned = try alloc.dupe(u8, &[_]u8{1}) };
            var h2 = H{ .owned = try alloc.dupe(u8, &[_]u8{2}) };
            _ = try P.add(alloc, &h1);
            _ = try P.add(alloc, &h2);
            try P.deinitItemsAuto(alloc);
            try std.testing.expectEqual(@as(usize, 2), H.calls);
            // const pool is constCast-ed to mutable inside: mutation visible
            try std.testing.expectEqual(@as(usize, 0), h1.owned.len);
            try std.testing.expectEqual(@as(usize, 0), h2.owned.len);
        }
    }

    // ---- deinit, self *const T ----
    {
        const H = struct {
            owned: []u8,
            var calls: usize = 0;
            pub fn deinit(self: *const @This(), a: std.mem.Allocator) void {
                a.free(self.owned);
                calls += 1;
            }
        };
        {
            const P = ResourceStore(H, .default);
            defer P.deinit(alloc);
            H.calls = 0;
            _ = try P.add(alloc, .{ .owned = try alloc.dupe(u8, &[_]u8{1}) });
            _ = try P.add(alloc, .{ .owned = try alloc.dupe(u8, &[_]u8{2}) });
            try P.deinitItemsAuto(alloc);
            try std.testing.expectEqual(@as(usize, 2), H.calls);
        }
        {
            const P = ResourceStore(*H, .default);
            defer P.deinit(alloc);
            H.calls = 0;
            var h1 = H{ .owned = try alloc.dupe(u8, &[_]u8{1}) };
            var h2 = H{ .owned = try alloc.dupe(u8, &[_]u8{2}) };
            _ = try P.add(alloc, &h1);
            _ = try P.add(alloc, &h2);
            try P.deinitItemsAuto(alloc);
            try std.testing.expectEqual(@as(usize, 2), H.calls);
        }
        {
            const P = ResourceStore(*const H, .default);
            defer P.deinit(alloc);
            H.calls = 0;
            var h1 = H{ .owned = try alloc.dupe(u8, &[_]u8{1}) };
            var h2 = H{ .owned = try alloc.dupe(u8, &[_]u8{2}) };
            _ = try P.add(alloc, &h1);
            _ = try P.add(alloc, &h2);
            try P.deinitItemsAuto(alloc);
            try std.testing.expectEqual(@as(usize, 2), H.calls);
        }
    }

    // ---- deinit, self *anyopaque ----
    {
        const H = struct {
            owned: []u8,
            var calls: usize = 0;
            pub fn deinit(self: *anyopaque, a: std.mem.Allocator) void {
                const this: *@This() = @ptrCast(@alignCast(self));
                a.free(this.owned);
                this.owned = &.{};
                calls += 1;
            }
        };
        {
            const P = ResourceStore(H, .default);
            defer P.deinit(alloc);
            H.calls = 0;
            const r1 = try P.add(alloc, .{ .owned = try alloc.dupe(u8, &[_]u8{1}) });
            const r2 = try P.add(alloc, .{ .owned = try alloc.dupe(u8, &[_]u8{2}) });
            try P.deinitItemsAuto(alloc);
            try std.testing.expectEqual(@as(usize, 2), H.calls);
            try std.testing.expectEqual(@as(usize, 0), P.get(r1).?.owned.len);
            try std.testing.expectEqual(@as(usize, 0), P.get(r2).?.owned.len);
        }
        {
            const P = ResourceStore(*H, .default);
            defer P.deinit(alloc);
            H.calls = 0;
            var h1 = H{ .owned = try alloc.dupe(u8, &[_]u8{1}) };
            var h2 = H{ .owned = try alloc.dupe(u8, &[_]u8{2}) };
            _ = try P.add(alloc, &h1);
            _ = try P.add(alloc, &h2);
            try P.deinitItemsAuto(alloc);
            try std.testing.expectEqual(@as(usize, 2), H.calls);
            try std.testing.expectEqual(@as(usize, 0), h1.owned.len);
            try std.testing.expectEqual(@as(usize, 0), h2.owned.len);
        }
        {
            const P = ResourceStore(*const H, .default);
            defer P.deinit(alloc);
            H.calls = 0;
            var h1 = H{ .owned = try alloc.dupe(u8, &[_]u8{1}) };
            var h2 = H{ .owned = try alloc.dupe(u8, &[_]u8{2}) };
            _ = try P.add(alloc, &h1);
            _ = try P.add(alloc, &h2);
            try P.deinitItemsAuto(alloc);
            try std.testing.expectEqual(@as(usize, 2), H.calls);
            try std.testing.expectEqual(@as(usize, 0), h1.owned.len);
            try std.testing.expectEqual(@as(usize, 0), h2.owned.len);
        }
    }

    // ---- deinit, self *const anyopaque ----
    {
        const H = struct {
            owned: []u8,
            var calls: usize = 0;
            pub fn deinit(self: *const anyopaque, a: std.mem.Allocator) void {
                const this: *const @This() = @ptrCast(@alignCast(self));
                a.free(this.owned);
                calls += 1;
            }
        };
        {
            const P = ResourceStore(H, .default);
            defer P.deinit(alloc);
            H.calls = 0;
            _ = try P.add(alloc, .{ .owned = try alloc.dupe(u8, &[_]u8{1}) });
            _ = try P.add(alloc, .{ .owned = try alloc.dupe(u8, &[_]u8{2}) });
            try P.deinitItemsAuto(alloc);
            try std.testing.expectEqual(@as(usize, 2), H.calls);
        }
        {
            const P = ResourceStore(*H, .default);
            defer P.deinit(alloc);
            H.calls = 0;
            var h1 = H{ .owned = try alloc.dupe(u8, &[_]u8{1}) };
            var h2 = H{ .owned = try alloc.dupe(u8, &[_]u8{2}) };
            _ = try P.add(alloc, &h1);
            _ = try P.add(alloc, &h2);
            try P.deinitItemsAuto(alloc);
            try std.testing.expectEqual(@as(usize, 2), H.calls);
        }
        {
            const P = ResourceStore(*const H, .default);
            defer P.deinit(alloc);
            H.calls = 0;
            var h1 = H{ .owned = try alloc.dupe(u8, &[_]u8{1}) };
            var h2 = H{ .owned = try alloc.dupe(u8, &[_]u8{2}) };
            _ = try P.add(alloc, &h1);
            _ = try P.add(alloc, &h2);
            try P.deinitItemsAuto(alloc);
            try std.testing.expectEqual(@as(usize, 2), H.calls);
        }
    }

    // ---- destroy, self by value (T) ----
    {
        const H = struct {
            owned: []u8,
            var calls: usize = 0;
            pub fn destroy(self: @This(), a: std.mem.Allocator) void {
                a.free(self.owned);
                calls += 1;
            }
        };
        {
            const P = ResourceStore(H, .default);
            defer P.deinit(alloc);
            H.calls = 0;
            _ = try P.add(alloc, .{ .owned = try alloc.dupe(u8, &[_]u8{1}) });
            _ = try P.add(alloc, .{ .owned = try alloc.dupe(u8, &[_]u8{2}) });
            try P.deinitItemsAuto(alloc);
            try std.testing.expectEqual(@as(usize, 2), H.calls);
        }
        {
            const P = ResourceStore(*H, .default);
            defer P.deinit(alloc);
            H.calls = 0;
            var h1 = H{ .owned = try alloc.dupe(u8, &[_]u8{1}) };
            var h2 = H{ .owned = try alloc.dupe(u8, &[_]u8{2}) };
            _ = try P.add(alloc, &h1);
            _ = try P.add(alloc, &h2);
            try P.deinitItemsAuto(alloc);
            try std.testing.expectEqual(@as(usize, 2), H.calls);
        }
        {
            const P = ResourceStore(*const H, .default);
            defer P.deinit(alloc);
            H.calls = 0;
            var h1 = H{ .owned = try alloc.dupe(u8, &[_]u8{1}) };
            var h2 = H{ .owned = try alloc.dupe(u8, &[_]u8{2}) };
            _ = try P.add(alloc, &h1);
            _ = try P.add(alloc, &h2);
            try P.deinitItemsAuto(alloc);
            try std.testing.expectEqual(@as(usize, 2), H.calls);
        }
    }

    // ---- destroy, self *T ----
    {
        const H = struct {
            owned: []u8,
            var calls: usize = 0;
            pub fn destroy(self: *@This(), a: std.mem.Allocator) void {
                a.free(self.owned);
                self.owned = &.{};
                calls += 1;
            }
        };
        {
            const P = ResourceStore(H, .default);
            defer P.deinit(alloc);
            H.calls = 0;
            const r1 = try P.add(alloc, .{ .owned = try alloc.dupe(u8, &[_]u8{1}) });
            const r2 = try P.add(alloc, .{ .owned = try alloc.dupe(u8, &[_]u8{2}) });
            try P.deinitItemsAuto(alloc);
            try std.testing.expectEqual(@as(usize, 2), H.calls);
            try std.testing.expectEqual(@as(usize, 0), P.get(r1).?.owned.len);
            try std.testing.expectEqual(@as(usize, 0), P.get(r2).?.owned.len);
        }
        {
            const P = ResourceStore(*H, .default);
            defer P.deinit(alloc);
            H.calls = 0;
            var h1 = H{ .owned = try alloc.dupe(u8, &[_]u8{1}) };
            var h2 = H{ .owned = try alloc.dupe(u8, &[_]u8{2}) };
            _ = try P.add(alloc, &h1);
            _ = try P.add(alloc, &h2);
            try P.deinitItemsAuto(alloc);
            try std.testing.expectEqual(@as(usize, 2), H.calls);
            try std.testing.expectEqual(@as(usize, 0), h1.owned.len);
            try std.testing.expectEqual(@as(usize, 0), h2.owned.len);
        }
        {
            const P = ResourceStore(*const H, .default);
            defer P.deinit(alloc);
            H.calls = 0;
            var h1 = H{ .owned = try alloc.dupe(u8, &[_]u8{1}) };
            var h2 = H{ .owned = try alloc.dupe(u8, &[_]u8{2}) };
            _ = try P.add(alloc, &h1);
            _ = try P.add(alloc, &h2);
            try P.deinitItemsAuto(alloc);
            try std.testing.expectEqual(@as(usize, 2), H.calls);
            try std.testing.expectEqual(@as(usize, 0), h1.owned.len);
            try std.testing.expectEqual(@as(usize, 0), h2.owned.len);
        }
    }

    // ---- destroy, self *const T ----
    {
        const H = struct {
            owned: []u8,
            var calls: usize = 0;
            pub fn destroy(self: *const @This(), a: std.mem.Allocator) void {
                a.free(self.owned);
                calls += 1;
            }
        };
        {
            const P = ResourceStore(H, .default);
            defer P.deinit(alloc);
            H.calls = 0;
            _ = try P.add(alloc, .{ .owned = try alloc.dupe(u8, &[_]u8{1}) });
            _ = try P.add(alloc, .{ .owned = try alloc.dupe(u8, &[_]u8{2}) });
            try P.deinitItemsAuto(alloc);
            try std.testing.expectEqual(@as(usize, 2), H.calls);
        }
        {
            const P = ResourceStore(*H, .default);
            defer P.deinit(alloc);
            H.calls = 0;
            var h1 = H{ .owned = try alloc.dupe(u8, &[_]u8{1}) };
            var h2 = H{ .owned = try alloc.dupe(u8, &[_]u8{2}) };
            _ = try P.add(alloc, &h1);
            _ = try P.add(alloc, &h2);
            try P.deinitItemsAuto(alloc);
            try std.testing.expectEqual(@as(usize, 2), H.calls);
        }
        {
            const P = ResourceStore(*const H, .default);
            defer P.deinit(alloc);
            H.calls = 0;
            var h1 = H{ .owned = try alloc.dupe(u8, &[_]u8{1}) };
            var h2 = H{ .owned = try alloc.dupe(u8, &[_]u8{2}) };
            _ = try P.add(alloc, &h1);
            _ = try P.add(alloc, &h2);
            try P.deinitItemsAuto(alloc);
            try std.testing.expectEqual(@as(usize, 2), H.calls);
        }
    }

    // ---- destroy, self *anyopaque ----
    {
        const H = struct {
            owned: []u8,
            var calls: usize = 0;
            pub fn destroy(self: *anyopaque, a: std.mem.Allocator) void {
                const this: *@This() = @ptrCast(@alignCast(self));
                a.free(this.owned);
                this.owned = &.{};
                calls += 1;
            }
        };
        {
            const P = ResourceStore(H, .default);
            defer P.deinit(alloc);
            H.calls = 0;
            const r1 = try P.add(alloc, .{ .owned = try alloc.dupe(u8, &[_]u8{1}) });
            const r2 = try P.add(alloc, .{ .owned = try alloc.dupe(u8, &[_]u8{2}) });
            try P.deinitItemsAuto(alloc);
            try std.testing.expectEqual(@as(usize, 2), H.calls);
            try std.testing.expectEqual(@as(usize, 0), P.get(r1).?.owned.len);
            try std.testing.expectEqual(@as(usize, 0), P.get(r2).?.owned.len);
        }
        {
            const P = ResourceStore(*H, .default);
            defer P.deinit(alloc);
            H.calls = 0;
            var h1 = H{ .owned = try alloc.dupe(u8, &[_]u8{1}) };
            var h2 = H{ .owned = try alloc.dupe(u8, &[_]u8{2}) };
            _ = try P.add(alloc, &h1);
            _ = try P.add(alloc, &h2);
            try P.deinitItemsAuto(alloc);
            try std.testing.expectEqual(@as(usize, 2), H.calls);
            try std.testing.expectEqual(@as(usize, 0), h1.owned.len);
            try std.testing.expectEqual(@as(usize, 0), h2.owned.len);
        }
        {
            const P = ResourceStore(*const H, .default);
            defer P.deinit(alloc);
            H.calls = 0;
            var h1 = H{ .owned = try alloc.dupe(u8, &[_]u8{1}) };
            var h2 = H{ .owned = try alloc.dupe(u8, &[_]u8{2}) };
            _ = try P.add(alloc, &h1);
            _ = try P.add(alloc, &h2);
            try P.deinitItemsAuto(alloc);
            try std.testing.expectEqual(@as(usize, 2), H.calls);
            try std.testing.expectEqual(@as(usize, 0), h1.owned.len);
            try std.testing.expectEqual(@as(usize, 0), h2.owned.len);
        }
    }

    // ---- destroy, self *const anyopaque ----
    {
        const H = struct {
            owned: []u8,
            var calls: usize = 0;
            pub fn destroy(self: *const anyopaque, a: std.mem.Allocator) void {
                const this: *const @This() = @ptrCast(@alignCast(self));
                a.free(this.owned);
                calls += 1;
            }
        };
        {
            const P = ResourceStore(H, .default);
            defer P.deinit(alloc);
            H.calls = 0;
            _ = try P.add(alloc, .{ .owned = try alloc.dupe(u8, &[_]u8{1}) });
            _ = try P.add(alloc, .{ .owned = try alloc.dupe(u8, &[_]u8{2}) });
            try P.deinitItemsAuto(alloc);
            try std.testing.expectEqual(@as(usize, 2), H.calls);
        }
        {
            const P = ResourceStore(*H, .default);
            defer P.deinit(alloc);
            H.calls = 0;
            var h1 = H{ .owned = try alloc.dupe(u8, &[_]u8{1}) };
            var h2 = H{ .owned = try alloc.dupe(u8, &[_]u8{2}) };
            _ = try P.add(alloc, &h1);
            _ = try P.add(alloc, &h2);
            try P.deinitItemsAuto(alloc);
            try std.testing.expectEqual(@as(usize, 2), H.calls);
        }
        {
            const P = ResourceStore(*const H, .default);
            defer P.deinit(alloc);
            H.calls = 0;
            var h1 = H{ .owned = try alloc.dupe(u8, &[_]u8{1}) };
            var h2 = H{ .owned = try alloc.dupe(u8, &[_]u8{2}) };
            _ = try P.add(alloc, &h1);
            _ = try P.add(alloc, &h2);
            try P.deinitItemsAuto(alloc);
            try std.testing.expectEqual(@as(usize, 2), H.calls);
        }
    }
}

test "ResourceStore isolates instances by tag" {
    const alloc = std.testing.allocator;
    const R = struct { v: i32 };

    const A = ResourceStore(R, .a);
    const B = ResourceStore(R, .b);
    const A2 = ResourceStore(R, .a);
    defer A.deinit(alloc);
    defer B.deinit(alloc);
    // A and A2 share storage; B is fully isolated.

    try std.testing.expect(A.tag_value == .a);
    try std.testing.expect(B.tag_value == .b);
    try std.testing.expect(A.Resource == A2.Resource);
    try std.testing.expect(A.Resource != B.Resource);

    const ra: A.Resource = try A.add(alloc, .{ .v = 7 });
    try std.testing.expectEqual(@as(usize, 1), A.liveCount());
    try std.testing.expectEqual(@as(usize, 0), B.liveCount());
    try std.testing.expectEqual(@as(usize, 1), A2.liveCount());

    // Same (T, tag) sees the same slot…
    try std.testing.expect(A2.isAlive(ra));
    try std.testing.expectEqual(@as(i32, 7), A2.get(ra).?.v);
    // …while a different tag does not (same id, foreign generation space).
    const foreign: B.Resource = .{ .id = ra.id, .gen = ra.gen };
    try std.testing.expect(!B.isAlive(foreign));
    try std.testing.expect(B.get(foreign) == null);

    // Refs resolve through their own tagged store.
    try std.testing.expect(ra.isAlive());
    try std.testing.expectEqual(@as(i32, 7), ra.get().?.v);

    const rb: B.Resource = try B.add(alloc, .{ .v = 42 });
    try std.testing.expectEqual(@as(usize, 1), A.liveCount());
    try std.testing.expectEqual(@as(usize, 1), B.liveCount());
    try std.testing.expectEqual(@as(i32, 7), ra.get().?.v);
    try std.testing.expectEqual(@as(i32, 42), rb.get().?.v);

    // Removing from one instance does not affect the other.
    _ = try A.remove(alloc, ra);
    try std.testing.expectEqual(@as(usize, 0), A.liveCount());
    try std.testing.expectEqual(@as(usize, 1), B.liveCount());
    try std.testing.expect(rb.isAlive());
}
