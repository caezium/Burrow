using CommunityToolkit.Mvvm.ComponentModel;
using BurrowWin.Services;

namespace BurrowWin.Models;

public partial class InstalledApplication : ObservableObject
{
    public InstalledApplication(
        string id,
        string name,
        string? publisher,
        string? version,
        string? installLocation,
        string? uninstallString,
        string source,
        long sizeBytes)
    {
        Id = id;
        Name = name;
        Publisher = publisher ?? string.Empty;
        Version = version ?? string.Empty;
        InstallLocation = installLocation ?? string.Empty;
        UninstallString = uninstallString ?? string.Empty;
        Source = source;
        SizeBytes = sizeBytes;
    }

    public string Id { get; }

    public string Name { get; }

    public string Publisher { get; }

    public string Version { get; }

    public string InstallLocation { get; }

    public string UninstallString { get; }

    public string Source { get; }

    public long SizeBytes { get; }

    public string SizeText => SizeBytes <= 0 ? "Unknown" : SystemTelemetryFormatter.Bytes(SizeBytes);

    public string Initials => string.IsNullOrWhiteSpace(Name) ? "?" : Name[..1].ToUpperInvariant();

    public string DetailLine
    {
        get
        {
            var location = string.IsNullOrWhiteSpace(InstallLocation) ? "No install path" : InstallLocation;
            return $"{SizeText} - {Source} - {location}";
        }
    }

    [ObservableProperty]
    private bool isSelected;
}
