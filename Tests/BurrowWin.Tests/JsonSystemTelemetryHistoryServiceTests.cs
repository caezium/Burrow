using BurrowWin.Models;
using BurrowWin.Services;
using Xunit;

namespace BurrowWin.Tests;

public sealed class JsonSystemTelemetryHistoryServiceTests : IDisposable
{
    private readonly string _tempRoot = Path.Combine(Path.GetTempPath(), "BurrowWinTests", Guid.NewGuid().ToString("N"));
    private readonly string _historyPath;

    public JsonSystemTelemetryHistoryServiceTests()
    {
        Directory.CreateDirectory(_tempRoot);
        _historyPath = Path.Combine(_tempRoot, "telemetry-history.jsonl");
    }

    [Fact]
    public async Task RecordAsync_AppendsTelemetrySnapshot()
    {
        var service = new JsonSystemTelemetryHistoryService(_historyPath);

        await service.RecordAsync(CreateSnapshot(1));

        var snapshots = await service.ReadRecentAsync(10);

        var snapshot = Assert.Single(snapshots);
        Assert.Equal(12.5, snapshot.CpuUsagePercent);
        Assert.Equal("GPU pending", snapshot.GpuStatus);
        Assert.Single(snapshot.TopProcesses);
    }

    [Fact]
    public async Task ReadRecentAsync_ReturnsNewestFirst_AndSkipsInvalidLines()
    {
        var service = new JsonSystemTelemetryHistoryService(_historyPath);

        await service.RecordAsync(CreateSnapshot(1));
        await File.AppendAllTextAsync(_historyPath, "not json" + Environment.NewLine);
        await service.RecordAsync(CreateSnapshot(2));
        await service.RecordAsync(CreateSnapshot(3));

        var snapshots = await service.ReadRecentAsync(2);

        Assert.Collection(
            snapshots,
            snapshot => Assert.Equal(DateTimeOffset.Parse("2026-06-15T00:03:00Z"), snapshot.CapturedAt),
            snapshot => Assert.Equal(DateTimeOffset.Parse("2026-06-15T00:02:00Z"), snapshot.CapturedAt));
    }

    public void Dispose()
    {
        if (Directory.Exists(_tempRoot))
        {
            Directory.Delete(_tempRoot, recursive: true);
        }
    }

    private static SystemTelemetrySnapshot CreateSnapshot(int offset)
    {
        return new SystemTelemetrySnapshot(
            DateTimeOffset.Parse("2026-06-15T00:00:00Z").AddMinutes(offset),
            12.5,
            50,
            4,
            8,
            75,
            3,
            4,
            100,
            50,
            "GPU pending",
            [new ProcessTelemetry("demo", 123, 4096)]);
    }
}
