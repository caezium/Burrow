using BurrowWin.Models;

namespace BurrowWin.Services;

public static class HistoryRangeCatalog
{
    public const string DefaultRangeKey = "1h";

    private const int MaximumReadLimit = 250000;

    public static IReadOnlyList<HistoryRangeDefinition> Ranges { get; } =
    [
        new("5m", "5m", TimeSpan.FromMinutes(5)),
        new("1h", "1h", TimeSpan.FromHours(1)),
        new("6h", "6h", TimeSpan.FromHours(6)),
        new("24h", "24h", TimeSpan.FromHours(24)),
        new("7d", "7d", TimeSpan.FromDays(7)),
        new("30d", "30d", TimeSpan.FromDays(30)),
        new("90d", "90d", TimeSpan.FromDays(90))
    ];

    public static HistoryRangeDefinition Resolve(string? key)
    {
        return Ranges.FirstOrDefault(
            range => string.Equals(range.Key, key, StringComparison.OrdinalIgnoreCase)) ??
            Ranges.First(range => range.Key == DefaultRangeKey);
    }

    public static int EstimateReadLimit(HistoryRangeDefinition range, int samplingIntervalSeconds)
    {
        var intervalSeconds = Math.Clamp(samplingIntervalSeconds, 5, 300);
        var estimated = (int)Math.Ceiling(range.Window.TotalSeconds / intervalSeconds) + 10;
        return Math.Clamp(estimated, 1, MaximumReadLimit);
    }

    public static IReadOnlyList<SystemTelemetrySnapshot> Filter(
        IEnumerable<SystemTelemetrySnapshot> samples,
        HistoryRangeDefinition range,
        DateTimeOffset rangeEnd)
    {
        var cutoff = rangeEnd - range.Window;
        return samples
            .Where(sample => sample.CapturedAt >= cutoff && sample.CapturedAt <= rangeEnd)
            .OrderByDescending(sample => sample.CapturedAt)
            .ToArray();
    }
}
