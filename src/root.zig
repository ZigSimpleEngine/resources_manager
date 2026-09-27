/// Global per-type resource pool with stable ids, free list, occupancy bitmap and generations.
pub const SlotPool = @import("pool.zig").SlotPool;

// Intended downstream wiring (this package stays dependency-free; the user
// wires it with resource abstractions in their own project):
//   const MeshPool = SlotPool(MyMeshRecord);      // one global pool per record type
//   const res: MeshPool.Resource = try MeshPool.add(alloc, record); // 4-byte ECS-ready ref
//   if (res.get()) |rec| { ... }                 // null when removed or stale
//   if (try MeshPool.remove(alloc, res)) |rec| { /* destroy separately */ }
//   var cur: ?MeshPool.Resource = null;
//   while (MeshPool.nextElement(cur)) |r| { cur = r; ... }

test {
    _ = @import("pool.zig");
    _ = @import("resource.zig");
}
