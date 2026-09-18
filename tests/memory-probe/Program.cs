using Microsoft.Diagnostics.Runtime;
using var target = DataTarget.AttachToProcess(int.Parse(args[0]), true);
var runtime = target.ClrVersions[0].CreateRuntime();
var totals = new Dictionary<string, (long count, ulong size)>();
foreach (var obj in runtime.Heap.EnumerateObjects()) {
    string name = obj.Type?.Name ?? "unknown";
    totals.TryGetValue(name, out var total);
    totals[name] = (total.count + 1, total.size + obj.Size);
}
// Resume the parent before writing to its redirected stdout pipe.
target.Dispose();
foreach (var item in totals.OrderByDescending(x => x.Value.size).Take(25))
    Console.WriteLine($"HEAP {item.Key} count={item.Value.count} bytes={item.Value.size}");
