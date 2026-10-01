/// Global per-type resource pool with stable ids, free list, occupancy bitmap and generations.
pub const SlotPool = @import("pool.zig").SlotPool;

// Intended downstream wiring (occupancy lives in `bit_tree.Bitset`):
//   const MeshPool = SlotPool(MyMeshRecord);      // one global pool per record type
//   const res: MeshPool.Resource = try MeshPool.add(alloc, record); // 4-byte ECS-ready ref
//   if (res.get()) |rec| { ... }                 // null when removed or stale
//   if (try MeshPool.remove(alloc, res)) |rec| { /* destroy separately */ }
//   const It = MeshPool.Iterator(*Ctx, Ctx.onItem, .forward);
//   _ = try It.iterateAll(&ctx, null, null);     // onItem(ctx, ref: Resource)

test {
    _ = @import("pool.zig");
    _ = @import("resource.zig");
}
