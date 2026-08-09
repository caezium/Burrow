using CommunityToolkit.Mvvm.ComponentModel;
using BurrowWin.Services;

namespace BurrowWin.Models;

public partial class LeftoverCandidate : ObservableObject
{
    public LeftoverCandidate(string category, string path, long sizeBytes, string? approvedScopeRoot = null)
    {
        Category = category;
        Path = path;
        SizeBytes = sizeBytes;
        ApprovedScopeRoot = string.IsNullOrWhiteSpace(approvedScopeRoot)
            ? System.IO.Path.GetDirectoryName(path) ?? string.Empty
            : approvedScopeRoot;
    }

    public string Category { get; }

    public string Path { get; }

    public long SizeBytes { get; }

    public string ApprovedScopeRoot { get; }

    public string SizeText => SystemTelemetryFormatter.Bytes(SizeBytes);

    [ObservableProperty]
    private bool isSelected;
}
