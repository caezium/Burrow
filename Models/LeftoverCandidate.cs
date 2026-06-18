using CommunityToolkit.Mvvm.ComponentModel;
using BurrowWin.Services;

namespace BurrowWin.Models;

public partial class LeftoverCandidate : ObservableObject
{
    public LeftoverCandidate(string category, string path, long sizeBytes)
    {
        Category = category;
        Path = path;
        SizeBytes = sizeBytes;
    }

    public string Category { get; }

    public string Path { get; }

    public long SizeBytes { get; }

    public string SizeText => SystemTelemetryFormatter.Bytes(SizeBytes);

    [ObservableProperty]
    private bool isSelected = true;
}
