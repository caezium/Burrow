using System.Text.Json;
using BurrowWin.Models;

namespace BurrowWin.Services;

public sealed class JsonApplicationSettingsService : IApplicationSettingsService
{
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        WriteIndented = true
    };

    private readonly object _sync = new();

    public JsonApplicationSettingsService()
        : this(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "BurrowWin",
            "settings.json"))
    {
    }

    public JsonApplicationSettingsService(string settingsFilePath)
    {
        SettingsFilePath = settingsFilePath;
        Current = ReadFromDisk();
    }

    public string SettingsFilePath { get; }

    public BurrowSettings Current { get; private set; }

    public event EventHandler<BurrowSettings>? SettingsChanged;

    public async Task<BurrowSettings> SaveAsync(
        BurrowSettings settings,
        CancellationToken cancellationToken = default)
    {
        var normalized = BurrowSettings.Normalize(settings);
        var directory = Path.GetDirectoryName(SettingsFilePath);
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }

        var json = JsonSerializer.Serialize(normalized, SerializerOptions);
        await File.WriteAllTextAsync(SettingsFilePath, json, cancellationToken).ConfigureAwait(false);

        lock (_sync)
        {
            Current = normalized;
        }

        SettingsChanged?.Invoke(this, normalized);
        return normalized;
    }

    public BurrowSettings Reload()
    {
        var settings = ReadFromDisk();
        lock (_sync)
        {
            Current = settings;
        }

        SettingsChanged?.Invoke(this, settings);
        return settings;
    }

    private BurrowSettings ReadFromDisk()
    {
        if (!File.Exists(SettingsFilePath))
        {
            return BurrowSettings.Normalize(null);
        }

        try
        {
            var json = File.ReadAllText(SettingsFilePath);
            return BurrowSettings.Normalize(JsonSerializer.Deserialize<BurrowSettings>(json, SerializerOptions));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException)
        {
            return BurrowSettings.Normalize(null);
        }
    }
}
