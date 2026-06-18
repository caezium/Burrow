using System.Text.Json;
using BurrowWin.Models;

namespace BurrowWin.Services;

public sealed class JsonOperationHistoryService : IOperationHistoryService
{
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        WriteIndented = false
    };

    private readonly SemaphoreSlim _writeLock = new(1, 1);

    public JsonOperationHistoryService()
        : this(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "BurrowWin",
            "history.jsonl"))
    {
    }

    public JsonOperationHistoryService(string historyFilePath)
    {
        HistoryFilePath = historyFilePath;
    }

    public string HistoryFilePath { get; }

    public async Task RecordAsync(OperationHistoryEntry entry, CancellationToken cancellationToken = default)
    {
        var directory = Path.GetDirectoryName(HistoryFilePath);
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }

        var line = JsonSerializer.Serialize(entry, SerializerOptions);

        await _writeLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await File.AppendAllTextAsync(HistoryFilePath, line + Environment.NewLine, cancellationToken)
                .ConfigureAwait(false);
        }
        finally
        {
            _writeLock.Release();
        }
    }

    public async Task<IReadOnlyList<OperationHistoryEntry>> ReadRecentAsync(
        int limit,
        CancellationToken cancellationToken = default)
    {
        if (limit <= 0 || !File.Exists(HistoryFilePath))
        {
            return [];
        }

        var lines = await File.ReadAllLinesAsync(HistoryFilePath, cancellationToken).ConfigureAwait(false);
        var entries = new List<OperationHistoryEntry>(Math.Min(limit, lines.Length));

        for (var index = lines.Length - 1; index >= 0 && entries.Count < limit; index--)
        {
            var line = lines[index];
            if (string.IsNullOrWhiteSpace(line))
            {
                continue;
            }

            try
            {
                var entry = JsonSerializer.Deserialize<OperationHistoryEntry>(line, SerializerOptions);
                if (entry is not null)
                {
                    entries.Add(entry);
                }
            }
            catch (JsonException)
            {
                continue;
            }
        }

        return entries;
    }
}
