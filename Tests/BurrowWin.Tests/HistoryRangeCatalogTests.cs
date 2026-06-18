using BurrowWin.Models;
using BurrowWin.Services;
using Xunit;

namespace BurrowWin.Tests;

public sealed class HistoryRangeCatalogTests
{
    [Fact]
    public void Resolve_ReturnsDefaultRangeForUnknownKey()
    {
        var range = HistoryRangeCatalog.Resolve("unknown");

        Assert.Equal("1h", range.Key);
        Assert.Equal(TimeSpan.FromHours(1), range.Window);
    }

    [Theory]
    [InlineData("5m", 60, 15)]
    [InlineData("1h", 60, 70)]
    [InlineData("6h", 30, 730)]
    public void EstimateReadLimit_UsesRangeWindowAndSamplingInterval(
        string key,
        int intervalSeconds,
        int expected)
    {
        var range = HistoryRangeCatalog.Resolve(key);

        Assert.Equal(expected, HistoryRangeCatalog.EstimateReadLimit(range, intervalSeconds));
    }

    [Fact]
    public void Filter_ReturnsSamplesInsideSelectedWindowNewestFirst()
    {
        var rangeEnd = DateTimeOffset.Parse("2026-06-15T12:00:00Z");
        var samples = new[]
        {
            CreateSnapshot(rangeEnd.AddMinutes(-10)),
            CreateSnapshot(rangeEnd.AddMinutes(-2)),
            CreateSnapshot(rangeEnd.AddMinutes(-4)),
            CreateSnapshot(rangeEnd.AddMinutes(1))
        };

        var filtered = HistoryRangeCatalog.Filter(samples, HistoryRangeCatalog.Resolve("5m"), rangeEnd);

        Assert.Equal(
            new[] { rangeEnd.AddMinutes(-2), rangeEnd.AddMinutes(-4) },
            filtered.Select(sample => sample.CapturedAt));
    }

    private static SystemTelemetrySnapshot CreateSnapshot(DateTimeOffset capturedAt)
    {
        return new SystemTelemetrySnapshot(
            capturedAt,
            10,
            20,
            2,
            8,
            30,
            3,
            10,
            100,
            50,
            "GPU pending",
            []);
    }
}
