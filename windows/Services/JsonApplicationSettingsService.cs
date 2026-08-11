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
        var (settings, shouldPersist) = ReadFromDisk();
        Current = settings;
        if (shouldPersist)
        {
            TryWriteToDisk(settings);
        }
    }

    public string SettingsFilePath { get; }

    public BurrowSettings Current { get; private set; }

    public event EventHandler<BurrowSettings>? SettingsChanged;

    public async Task<BurrowSettings> SaveAsync(
        BurrowSettings settings,
        CancellationToken cancellationToken = default)
    {
        // Settings callers commonly construct a fresh model. Preserve the
        // per-install credential across ordinary saves instead of silently
        // rotating it and breaking a running stdio bridge.
        settings.HttpServerAuthToken = Current.HttpServerAuthToken;
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
        var (settings, shouldPersist) = ReadFromDisk();
        if (shouldPersist)
        {
            TryWriteToDisk(settings);
        }
        lock (_sync)
        {
            Current = settings;
        }

        SettingsChanged?.Invoke(this, settings);
        return settings;
    }

    private (BurrowSettings Settings, bool ShouldPersist) ReadFromDisk()
    {
        if (!File.Exists(SettingsFilePath))
        {
            return (BurrowSettings.Normalize(null), true);
        }

        try
        {
            var json = File.ReadAllText(SettingsFilePath);
            using var document = JsonDocument.Parse(json);
            var hasPersistedCredential = document.RootElement.ValueKind == JsonValueKind.Object
                && document.RootElement.TryGetProperty("HttpServerAuthToken", out var credentialElement)
                && credentialElement.ValueKind == JsonValueKind.String
                && BurrowSettings.IsValidHttpServerAuthToken(credentialElement.GetString());
            var decoded = JsonSerializer.Deserialize<BurrowSettings>(json, SerializerOptions);
            return (BurrowSettings.Normalize(decoded), !hasPersistedCredential);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException)
        {
            // Do not overwrite a malformed or inaccessible user file. The app
            // can run with safe defaults, and a later explicit Save repairs it.
            return (BurrowSettings.Normalize(null), false);
        }
    }

    private void WriteToDisk(BurrowSettings settings)
    {
        var directory = Path.GetDirectoryName(SettingsFilePath);
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }
        File.WriteAllText(SettingsFilePath, JsonSerializer.Serialize(settings, SerializerOptions));
    }

    private void TryWriteToDisk(BurrowSettings settings)
    {
        try
        {
            WriteToDisk(settings);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // The listener remains fail-closed with its in-memory credential;
            // an explicit Save can surface and repair the storage problem.
        }
    }
}
