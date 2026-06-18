using System.Text.Json;
using BurrowWin.Models;

namespace BurrowWin.Services;

public sealed class JsonSystemTelemetryHistoryService : ISystemTelemetryHistoryService
{
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        WriteIndented = false
    };

    private readonly SemaphoreSlim _writeLock = new(1, 1);
    private readonly Func<int> _historyRetentionDaysProvider;

    public JsonSystemTelemetryHistoryService()
        : this(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "BurrowWin",
            "telemetry-history.jsonl"))
    {
    }

    public JsonSystemTelemetryHistoryService(IApplicationSettingsService settingsService)
        : this(
            Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "BurrowWin",
                "telemetry-history.jsonl"),
            () => settingsService.Current.HistoryRetentionDays)
    {
    }

    public JsonSystemTelemetryHistoryService(string historyFilePath)
        : this(historyFilePath, () => BurrowSettings.DefaultHistoryRetentionDays)
    {
    }

    public JsonSystemTelemetryHistoryService(string historyFilePath, Func<int> historyRetentionDaysProvider)
    {
        HistoryFilePath = historyFilePath;
        _historyRetentionDaysProvider = historyRetentionDaysProvider;
    }

    public string HistoryFilePath { get; }

    public async Task RecordAsync(SystemTelemetrySnapshot snapshot, CancellationToken cancellationToken = default)
    {
        var directory = Path.GetDirectoryName(HistoryFilePath);
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }

        var line = JsonSerializer.Serialize(snapshot, SerializerOptions);
        await _writeLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await File.AppendAllTextAsync(HistoryFilePath, line + Environment.NewLine, cancellationToken)
                .ConfigureAwait(false);
            await PruneAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _writeLock.Release();
        }
    }

    public async Task<IReadOnlyList<SystemTelemetrySnapshot>> ReadRecentAsync(
        int limit,
        CancellationToken cancellationToken = default)
    {
        if (limit <= 0 || !File.Exists(HistoryFilePath))
        {
            return [];
        }

        var lines = await File.ReadAllLinesAsync(HistoryFilePath, cancellationToken).ConfigureAwait(false);
        var snapshots = new List<SystemTelemetrySnapshot>(Math.Min(limit, lines.Length));

        for (var index = lines.Length - 1; index >= 0 && snapshots.Count < limit; index--)
        {
            var line = lines[index];
            if (string.IsNullOrWhiteSpace(line))
            {
                continue;
            }

            try
            {
                var snapshot = JsonSerializer.Deserialize<SystemTelemetrySnapshot>(line, SerializerOptions);
                if (snapshot is not null)
                {
                    snapshots.Add(snapshot);
                }
            }
            catch (JsonException)
            {
                continue;
            }
        }

        return snapshots;
    }

    private async Task PruneAsync(CancellationToken cancellationToken)
    {
        var retentionDays = _historyRetentionDaysProvider();
        if (retentionDays <= 0 || !File.Exists(HistoryFilePath))
        {
            return;
        }

        var cutoff = DateTimeOffset.UtcNow.AddDays(-retentionDays);
        var lines = await File.ReadAllLinesAsync(HistoryFilePath, cancellationToken).ConfigureAwait(false);
        var retained = new List<string>(lines.Length);
        var changed = false;

        foreach (var line in lines)
        {
            if (string.IsNullOrWhiteSpace(line))
            {
                changed = true;
                continue;
            }

            try
            {
                var snapshot = JsonSerializer.Deserialize<SystemTelemetrySnapshot>(line, SerializerOptions);
                if (snapshot is null || snapshot.CapturedAt < cutoff)
                {
                    changed = true;
                    continue;
                }
            }
            catch (JsonException)
            {
            }

            retained.Add(line);
        }

        if (changed)
        {
            await File.WriteAllLinesAsync(HistoryFilePath, retained, cancellationToken).ConfigureAwait(false);
        }
    }
}
