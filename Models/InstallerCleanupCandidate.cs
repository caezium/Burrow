using CommunityToolkit.Mvvm.ComponentModel;
using BurrowWin.Services;

namespace BurrowWin.Models;

public partial class InstallerCleanupCandidate : ObservableObject
{
    public InstallerCleanupCandidate(
        string name,
        string path,
        string kind,
        long sizeBytes,
        DateTimeOffset lastWriteTime)
    {
        Name = name;
        Path = path;
        Kind = kind;
        SizeBytes = sizeBytes;
        LastWriteTime = lastWriteTime;
    }

    public string Name { get; }

    public string Path { get; }

    public string Kind { get; }

    public long SizeBytes { get; }

    public DateTimeOffset LastWriteTime { get; }

    public string SizeText => SystemTelemetryFormatter.Bytes(SizeBytes);

    public string LastTouchedText => LastWriteTime.ToLocalTime().ToString("yyyy-MM-dd");

    public string DetailLine => $"{SizeText} - {Kind} - {Path}";

    [ObservableProperty]
    private bool isSelected = true;
}
