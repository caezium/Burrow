using BurrowWin.Models;
using BurrowWin.Services;
using Xunit;

namespace BurrowWin.Tests;

public sealed class TrayHudStatusFormatterTests
{
    [Fact]
    public void Build_ReturnsWarmupStatus_WhenSnapshotAndActivityAreMissing()
    {
        var status = TrayHudStatusFormatter.Build(null, null);

        Assert.Equal("No telemetry sample yet", status.SampleText);
        Assert.Equal("--", status.HealthScore);
        Assert.Equal("warming up", status.HealthLabel);
        Assert.Equal("--", status.CpuText);
        Assert.Equal("--", status.MemoryText);
        Assert.Equal("--", status.DiskText);
        Assert.Equal("--", status.NetworkText);
        Assert.Equal("No activity", status.ActivityTitle);
        Assert.Empty(status.TopProcesses);
    }

    [Fact]
    public void Build_FormatsTelemetryActivityAndTopProcesses()
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
            new[]
            {
                new ProcessTelemetry("editor", 10, 900, 5, 10),
                new ProcessTelemetry("compiler", 20, 700, 35, 40),
                new ProcessTelemetry("browser", 30, 1200, 20, 50),
                new ProcessTelemetry("terminal", 40, 500, 10, 15),
                new ProcessTelemetry("backup", 50, 300, 1, 80)
            });
        var activity = new OperationHistoryEntry(
            DateTimeOffset.Parse("2026-06-15T08:31:05Z"),
            "local",
            "clean",
            "--dry-run",
            0,
            true,
            120,
            "Previewed 4 items");

        var status = TrayHudStatusFormatter.Build(snapshot, activity);

        Assert.Equal("65", status.HealthScore);
        Assert.Equal("Watch", status.HealthLabel);
        Assert.Equal("24.2%", status.CpuText);
        Assert.Equal("51.8%", status.MemoryText);
        Assert.Equal("70%", status.DiskText);
        Assert.Equal("2 KB/s down / 1 KB/s up", status.NetworkText);
        Assert.Equal("clean - Succeeded (0)", status.ActivityTitle);
        Assert.Contains("Previewed 4 items", status.ActivityDetail);
        Assert.Equal(new[] { "compiler", "browser", "terminal", "editor" }, status.TopProcesses.Select(process => process.Name));
    }
}
