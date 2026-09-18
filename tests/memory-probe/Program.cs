using Microsoft.Diagnostics.Runtime;
using var target = DataTarget.AttachToProcess(int.Parse(args[0]), true);
var runtime = target.ClrVersions[0].CreateRuntime();
var strings = new List<string>();
var totals = new Dictionary<string, (long count, ulong size)>();
foreach (var obj in runtime.Heap.EnumerateObjects()) {
    string name = obj.Type?.Name ?? "unknown";
    totals.TryGetValue(name, out var total);
    if (name == "System.String" && obj.Size > 100000) {
        string value = obj.AsString(2000000);
        string[] patterns = { "Management", "Automation", "Collections", "PSParameterizedProperty", "PSObject", "PSCustomObject", "DateTime", "Drawing", "Reflection", "ScriptBlock", "String" };
        // Only fixed category indexes and occurrence counts leave the process.
        // Never print raw heap strings, paths, credentials, or exception payloads.
        var counts = patterns.Select((pattern, index) => index + ":" + ((value.Length - value.Replace(pattern, "").Length) / pattern.Length));
        strings.Add("HEAP STRING bytes=" + obj.Size + " categories=" + string.Join(",", counts));
    }
    totals[name] = (total.count + 1, total.size + obj.Size);
}
// Resume the parent before writing to its redirected stdout pipe.
target.Dispose();
foreach (var item in totals.OrderByDescending(x => x.Value.size).Take(25))
    Console.WriteLine($"HEAP {item.Key} count={item.Value.count} bytes={item.Value.size}");

foreach (var item in strings.Take(10)) Console.WriteLine(item);
