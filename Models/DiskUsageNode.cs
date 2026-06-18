using System.Collections.ObjectModel;
using BurrowWin.Services;

namespace BurrowWin.Models;

public sealed class DiskUsageNode
{
    public DiskUsageNode(string name, string path, long sizeBytes, double percentOfParent, IEnumerable<DiskUsageNode>? children = null)
    {
        Name = name;
        Path = path;
        SizeBytes = sizeBytes;
        PercentOfParent = percentOfParent;
        Children = new ObservableCollection<DiskUsageNode>(children ?? []);
    }

    public string Name { get; }

    public string Path { get; }

    public long SizeBytes { get; }

    public double PercentOfParent { get; }

    public string SizeText => SystemTelemetryFormatter.Bytes(SizeBytes);

    public string PercentText => SystemTelemetryFormatter.Percent(PercentOfParent);

    public ObservableCollection<DiskUsageNode> Children { get; }
}
