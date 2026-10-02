/// Global per-type resource store with stable ids, free list, occupancy bitmap and generations.
pub const ResourceStore = @import("pool.zig").ResourceStore;
pub const Resource = @import("resource.zig").Resource;

// Intended downstream wiring (occupancy lives in `bit_tree.Bitset`):
//   const MeshStore = ResourceStore(MyMeshRecord, .default); // one global store per (record, tag)
//   const MeshStoreUI = ResourceStore(MyMeshRecord, .ui);     // isolated instance, same record type
//   const res: MeshStore.Resource = try MeshStore.add(alloc, record); // 4-byte ECS-ready ref
//   if (res.get()) |rec| { ... }                 // null when removed or stale
//   if (try MeshStore.remove(alloc, res)) |rec| { /* destroy separately */ }
//   const It = MeshStore.Iterator(*Ctx, Ctx.onItem, .forward);
//   _ = try It.iterateAll(&ctx, null, null);     // onItem(ctx, ref: Resource)

test {
    _ = @import("pool.zig");
    _ = @import("resource.zig");
}
