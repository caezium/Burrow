using BurrowWin.Models;
using BurrowWin.Services;
using Xunit;

namespace BurrowWin.Tests;

public sealed class TrayIconTextFormatterTests
{
    [Fact]
    public void BuildTooltip_ReturnsWarmupText_WhenSnapshotIsMissing()
    {
        Assert.Equal("BurrowWin - warming up", TrayIconTextFormatter.BuildTooltip(null));
    }

    [Fact]
    public void BuildTooltip_IncludesCpuAndMemoryPercentages()
    {
        var snapshot = new SystemTelemetrySnapshot(
            DateTimeOffset.Parse("2026-06-15T00:00:00Z"),
            24.2,
            51.8,
            4,
            8,
            70,
            3,
            4,
            100,
            50,
            "GPU pending",
            []);

        Assert.Equal("BurrowWin CPU 24% MEM 52%", TrayIconTextFormatter.BuildTooltip(snapshot));
    }

    [Fact]
    public void BuildMenuLines_ReturnStatusText_WhenSnapshotIsMissing()
    {
        Assert.Equal("Health pending", TrayIconTextFormatter.BuildHealthLine(null));
        Assert.Equal("CPU --  Memory --  Disk --", TrayIconTextFormatter.BuildResourceLine(null));
        Assert.Equal("Network --", TrayIconTextFormatter.BuildNetworkLine(null));
        Assert.Equal("No telemetry sample yet", TrayIconTextFormatter.BuildSampleLine(null));
    }

    [Fact]
    public void BuildMenuLines_FormatLatestSnapshot()
    {
        var snapshot = new SystemTelemetrySnapshot(
            DateTimeOffset.Parse("2026-06-15T08:30:05Z"),
            24.2,
            51.8,
            4,
            8,
            70,
            3,
            4,
            2048,
            1024,
            "GPU pending",
            []);

        Assert.Equal("Health 65 - Watch", TrayIconTextFormatter.BuildHealthLine(snapshot));
        Assert.Equal("CPU 24%  Memory 52%  Disk 70%", TrayIconTextFormatter.BuildResourceLine(snapshot));
        Assert.Equal("Network 2 KB/s down / 1 KB/s up", TrayIconTextFormatter.BuildNetworkLine(snapshot));
        Assert.Contains("Latest sample", TrayIconTextFormatter.BuildSampleLine(snapshot));
    }
}
