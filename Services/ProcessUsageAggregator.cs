using BurrowWin.Models;

namespace BurrowWin.Services;

public static class ProcessUsageAggregator
{
    public const string PeakMemoryMetric = "peak_working_set_bytes";
    public const string AverageMemoryMetric = "average_working_set_bytes";
    public const string PeakCpuMetric = "peak_cpu_usage_percent";
    public const string AverageCpuMetric = "average_cpu_usage_percent";
    public const string CpuTimeMetric = "total_processor_seconds";

    public static IReadOnlyList<ProcessUsageSummary> RankByPeakMemory(
        IEnumerable<SystemTelemetrySnapshot> snapshots,
        int limit)
    {
        return Rank(snapshots, PeakMemoryMetric, limit);
    }

    public static IReadOnlyList<ProcessUsageSummary> Rank(
        IEnumerable<SystemTelemetrySnapshot> snapshots,
        string metric,
        int limit)
    {
        var clampedLimit = Math.Clamp(limit, 1, 500);
        var normalizedMetric = NormalizeMetric(metric);
        var summaries = snapshots
            .SelectMany(snapshot => snapshot.TopProcesses)
            .GroupBy(process => (process.Name, process.ProcessId))
            .Select(CreateSummary);

        return summaries
            .OrderByDescending(summary => Score(summary, normalizedMetric))
            .ThenBy(summary => summary.Name, StringComparer.OrdinalIgnoreCase)
            .Take(clampedLimit)
            .ToArray();
    }

    public static string NormalizeMetric(string metric)
    {
        if (string.IsNullOrWhiteSpace(metric))
        {
            return PeakMemoryMetric;
        }

        return metric.Trim().ToLowerInvariant() switch
        {
            "peak_mem" or "memory" or "mem" or PeakMemoryMetric => PeakMemoryMetric,
            "avg_mem" or AverageMemoryMetric => AverageMemoryMetric,
            "peak_cpu" or "cpu" or PeakCpuMetric => PeakCpuMetric,
            "avg_cpu" or AverageCpuMetric => AverageCpuMetric,
            "cpu_time" or "total_cpu" or CpuTimeMetric => CpuTimeMetric,
            _ => PeakMemoryMetric
        };
    }

    private static ProcessUsageSummary CreateSummary(IGrouping<(string Name, int ProcessId), ProcessTelemetry> group)
    {
        return new ProcessUsageSummary(
            group.Key.Name,
            group.Key.ProcessId,
            group.Count(),
            group.Max(process => process.WorkingSetBytes),
            group.Average(process => process.WorkingSetBytes),
            group.Max(process => process.CpuUsagePercent),
            group.Average(process => process.CpuUsagePercent),
            group.Max(process => process.TotalProcessorSeconds));
    }

    private static double Score(ProcessUsageSummary summary, string metric)
    {
        return metric switch
        {
            AverageMemoryMetric => summary.AverageWorkingSetBytes,
            PeakCpuMetric => summary.PeakCpuUsagePercent,
            AverageCpuMetric => summary.AverageCpuUsagePercent,
            CpuTimeMetric => summary.TotalProcessorSeconds,
            _ => summary.PeakWorkingSetBytes
        };
    }
}
