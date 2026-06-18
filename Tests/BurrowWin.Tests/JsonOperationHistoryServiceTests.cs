using BurrowWin.Models;
using BurrowWin.Services;
using Xunit;

namespace BurrowWin.Tests;

public sealed class JsonOperationHistoryServiceTests : IDisposable
{
    private readonly string _tempRoot = Path.Combine(Path.GetTempPath(), "BurrowWinTests", Guid.NewGuid().ToString("N"));
    private readonly string _historyPath;

    public JsonOperationHistoryServiceTests()
    {
        Directory.CreateDirectory(_tempRoot);
        _historyPath = Path.Combine(_tempRoot, "history.jsonl");
    }

    [Fact]
    public async Task RecordAsync_AppendsJsonLine()
    {
        var service = new JsonOperationHistoryService(_historyPath);

        await service.RecordAsync(new OperationHistoryEntry(
            DateTimeOffset.Parse("2026-06-15T00:00:00Z"),
            "mole",
            "clean",
            "clean --dry-run",
            0,
            true,
            42,
            "Preview completed"));

        var entries = await service.ReadRecentAsync(10);

        var entry = Assert.Single(entries);
        Assert.Equal("clean", entry.Operation);
        Assert.Equal("mole", entry.Source);
        Assert.True(entry.Succeeded);
        Assert.Equal(42, entry.DurationMs);
    }

    [Fact]
    public async Task ReadRecentAsync_ReturnsNewestFirst_AndSkipsInvalidLines()
    {
        var service = new JsonOperationHistoryService(_historyPath);

        await service.RecordAsync(CreateEntry("clean", 1));
        await File.AppendAllTextAsync(_historyPath, "not json" + Environment.NewLine);
        await service.RecordAsync(CreateEntry("optimize", 2));
        await service.RecordAsync(CreateEntry("status", 3));

        var entries = await service.ReadRecentAsync(2);

        Assert.Collection(
            entries,
            entry => Assert.Equal("status", entry.Operation),
            entry => Assert.Equal("optimize", entry.Operation));
    }

    public void Dispose()
    {
        if (Directory.Exists(_tempRoot))
        {
            Directory.Delete(_tempRoot, recursive: true);
        }
    }

    private static OperationHistoryEntry CreateEntry(string operation, int offset)
    {
        return new OperationHistoryEntry(
            DateTimeOffset.Parse("2026-06-15T00:00:00Z").AddMinutes(offset),
            "test",
            operation,
            operation,
            0,
            true,
            1,
            "Done");
    }
}
