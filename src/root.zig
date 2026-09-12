/// Stable resource reference (`id` + `gen`).
pub const ResourceRef = @import("resource_ref.zig").ResourceRef;
/// Null (empty) resource reference.
pub const NO_REF = @import("resource_ref.zig").NO_REF;
/// Global per-type resource pool with stable ids, free list, occupancy bitmap and generations.
pub const SlotPool = @import("pool.zig").SlotPool;
/// ECS-compatible component referencing a pooled resource.
pub const EcsResource = @import("ecs_resource.zig").EcsResource;

// Intended downstream wiring (this package stays dependency-free; the user
// wires it with resource abstractions in their own project):
//   const MeshPool = SlotPool(MyMeshRecord);      // one global pool per record type
//   const MeshRef = EcsResource(MyMeshRecord);    // ECS component holding only a ref
//   const comp = MeshRef{ .ref = try MeshPool.add(alloc, record) };
//   if (comp.get()) |rec| { ... }                 // null when removed or stale
//   if (try MeshPool.remove(alloc, comp.ref)) |rec| { /* destroy separately */ }
//   var cur: ?ResourceRef = null;
//   while (MeshPool.nextElement(cur)) |r| { cur = r; ... }

test {
    _ = @import("resource_ref.zig");
    _ = @import("pool.zig");
    _ = @import("ecs_resource.zig");
}
