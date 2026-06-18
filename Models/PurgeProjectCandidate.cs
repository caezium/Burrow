using CommunityToolkit.Mvvm.ComponentModel;
using BurrowWin.Services;

namespace BurrowWin.Models;

public partial class PurgeProjectCandidate : ObservableObject
{
    public PurgeProjectCandidate(
        string name,
        string path,
        string marker,
        IReadOnlyList<PurgeArtifactCandidate> artifacts)
    {
        Name = name;
        Path = path;
        Marker = marker;
        Artifacts = artifacts;
        TotalSizeBytes = artifacts.Sum(artifact => artifact.SizeBytes);
    }

    public string Name { get; }

    public string Path { get; }

    public string Marker { get; }

    public IReadOnlyList<PurgeArtifactCandidate> Artifacts { get; }

    public long TotalSizeBytes { get; }

    public string TotalSizeText => SystemTelemetryFormatter.Bytes(TotalSizeBytes);

    public int ArtifactCount => Artifacts.Count;

    public string ArtifactSummary => string.Join(", ", Artifacts.Take(3).Select(artifact => artifact.Name));

    [ObservableProperty]
    private bool isSelected = true;
}
