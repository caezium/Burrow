using BurrowWin.Models;
using BurrowWin.Services;
using Xunit;

namespace BurrowWin.Tests;

public sealed class SystemTelemetryFormatterTests
{
    [Fact]
    public void Percent_ClampsAndFormats()
    {
        Assert.Equal("0%", SystemTelemetryFormatter.Percent(-4));
        Assert.Equal("12.3%", SystemTelemetryFormatter.Percent(12.34));
        Assert.Equal("100%", SystemTelemetryFormatter.Percent(120));
    }

    [Fact]
    public void Bytes_FormatsBinaryUnits()
    {
        Assert.Equal("999 B", SystemTelemetryFormatter.Bytes(999));
        Assert.Equal("1 KB", SystemTelemetryFormatter.Bytes(1024));
        Assert.Equal("1.5 GB", SystemTelemetryFormatter.Bytes(1_610_612_736));
    }

    [Fact]
    public void SnapshotSummaries_UseFormattedBytes()
    {
        var snapshot = new SystemTelemetrySnapshot(
            DateTimeOffset.UnixEpoch,
            10,
            50,
            4L * 1024 * 1024 * 1024,
            8L * 1024 * 1024 * 1024,
            25,
            128L * 1024 * 1024 * 1024,
            512L * 1024 * 1024 * 1024,
            1024,
            2048,
            "GPU pending",
            [new ProcessTelemetry("demo", 10, 2048)]);

        Assert.Equal("4 GB / 8 GB", SystemTelemetryFormatter.MemorySummary(snapshot));
        Assert.Equal("128 GB / 512 GB", SystemTelemetryFormatter.DiskSummary(snapshot));
        Assert.Equal("2 KB", snapshot.TopProcesses[0].WorkingSetText);
        Assert.Equal("0%", snapshot.TopProcesses[0].CpuUsageText);
        Assert.Equal("1 KB/s", SystemTelemetryFormatter.Rate(snapshot.NetworkReceivedBytesPerSecond));
    }
}
