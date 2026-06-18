using BurrowWin.Models;
using BurrowWin.Services;
using Xunit;

namespace BurrowWin.Tests;

public sealed class ProcessUsageAggregatorTests
{
    [Fact]
    public void RankByPeakMemory_GroupsByProcessAndRanksByPeakWorkingSet()
    {
        var snapshots = new[]
        {
            CreateSnapshot(
                new ProcessTelemetry("editor", 10, 100, 1, 10),
                new ProcessTelemetry("shell", 20, 300, 2, 20)),
            CreateSnapshot(
                new ProcessTelemetry("editor", 10, 450, 3, 30),
                new ProcessTelemetry("shell", 20, 200, 1, 40),
                new ProcessTelemetry("browser", 30, 350, 4, 50))
        };

        var ranked = ProcessUsageAggregator.RankByPeakMemory(snapshots, 2);

        Assert.Collection(
            ranked,
            process =>
            {
                Assert.Equal("editor", process.Name);
                Assert.Equal(10, process.ProcessId);
                Assert.Equal(2, process.SampleCount);
                Assert.Equal(450, process.PeakWorkingSetBytes);
                Assert.Equal(275, process.AverageWorkingSetBytes);
                Assert.Equal(3, process.PeakCpuUsagePercent);
                Assert.Equal(2, process.AverageCpuUsagePercent);
                Assert.Equal(30, process.TotalProcessorSeconds);
            },
            process =>
            {
                Assert.Equal("browser", process.Name);
                Assert.Equal(30, process.ProcessId);
                Assert.Equal(1, process.SampleCount);
                Assert.Equal(350, process.PeakWorkingSetBytes);
            });
    }

    [Fact]
    public void Rank_SupportsCpuAndAverageMemoryMetrics()
    {
        var snapshots = new[]
        {
            CreateSnapshot(
                new ProcessTelemetry("editor", 10, 900, 2, 30),
                new ProcessTelemetry("compiler", 20, 200, 45, 100)),
            CreateSnapshot(
                new ProcessTelemetry("editor", 10, 800, 3, 40),
                new ProcessTelemetry("compiler", 20, 300, 15, 130))
        };

        var byCpu = ProcessUsageAggregator.Rank(snapshots, "peak_cpu", 1);
        var byAverageMemory = ProcessUsageAggregator.Rank(snapshots, "avg_mem", 1);
        var byCpuTime = ProcessUsageAggregator.Rank(snapshots, "cpu_time", 1);

        Assert.Equal("compiler", Assert.Single(byCpu).Name);
        Assert.Equal("editor", Assert.Single(byAverageMemory).Name);
        Assert.Equal("compiler", Assert.Single(byCpuTime).Name);
    }

    [Theory]
    [InlineData("peak_cpu", ProcessUsageAggregator.PeakCpuMetric)]
    [InlineData("avg_cpu", ProcessUsageAggregator.AverageCpuMetric)]
    [InlineData("cpu_time", ProcessUsageAggregator.CpuTimeMetric)]
    [InlineData("avg_mem", ProcessUsageAggregator.AverageMemoryMetric)]
    [InlineData("unknown", ProcessUsageAggregator.PeakMemoryMetric)]
    public void NormalizeMetric_ReturnsSupportedMetric(string input, string expected)
    {
        Assert.Equal(expected, ProcessUsageAggregator.NormalizeMetric(input));
    }

    private static SystemTelemetrySnapshot CreateSnapshot(params ProcessTelemetry[] processes)
    {
        return new SystemTelemetrySnapshot(
            DateTimeOffset.Parse("2026-06-15T00:00:00Z"),
            10,
            50,
            4,
            8,
            70,
            3,
            4,
            100,
            50,
            "GPU pending",
            processes);
    }
}
