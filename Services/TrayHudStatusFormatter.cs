using BurrowWin.Models;

namespace BurrowWin.Services;

public static class TrayHudStatusFormatter
{
    public static TrayHudStatus Build(SystemTelemetrySnapshot? snapshot, OperationHistoryEntry? activity)
    {
        var telemetry = BuildTelemetry(snapshot);
        var activityText = BuildActivity(activity);

        return new TrayHudStatus(
            telemetry.SampleText,
            telemetry.HealthScore,
            telemetry.HealthLabel,
            telemetry.CpuText,
            telemetry.MemoryText,
            telemetry.DiskText,
            telemetry.NetworkText,
            activityText.ActivityTitle,
            activityText.ActivityDetail,
            telemetry.TopProcesses);
    }

    private static (
        string SampleText,
        string HealthScore,
        string HealthLabel,
        string CpuText,
        string MemoryText,
        string DiskText,
        string NetworkText,
        IReadOnlyList<ProcessTelemetry> TopProcesses) BuildTelemetry(SystemTelemetrySnapshot? snapshot)
    {
        if (snapshot is null)
        {
            return (
                "No telemetry sample yet",
                "--",
                "warming up",
                "--",
                "--",
                "--",
                "--",
                []);
        }

        var pressure = Math.Max(snapshot.CpuUsagePercent, Math.Max(snapshot.MemoryUsagePercent, snapshot.DiskUsagePercent));
        var score = Math.Clamp(100 - (int)Math.Round(pressure / 2), 0, 100);
        var topProcesses = snapshot.TopProcesses
            .OrderByDescending(process => process.CpuUsagePercent)
            .ThenByDescending(process => process.WorkingSetBytes)
            .Take(4)
            .ToArray();

        return (
            $"Updated {snapshot.CapturedAt.ToLocalTime():HH:mm:ss}",
            score.ToString(),
            score >= 80 ? "Good" : score >= 60 ? "Watch" : "Busy",
            SystemTelemetryFormatter.Percent(snapshot.CpuUsagePercent),
            SystemTelemetryFormatter.Percent(snapshot.MemoryUsagePercent),
            SystemTelemetryFormatter.Percent(snapshot.DiskUsagePercent),
            $"{SystemTelemetryFormatter.Rate(snapshot.NetworkReceivedBytesPerSecond)} down / {SystemTelemetryFormatter.Rate(snapshot.NetworkSentBytesPerSecond)} up",
            topProcesses);
    }

    private static (string ActivityTitle, string ActivityDetail) BuildActivity(OperationHistoryEntry? activity)
    {
        if (activity is null)
        {
            return ("No activity", "Burrow has not recorded an operation yet.");
        }

        return (
            $"{activity.Operation} - {activity.ResultText}",
            $"{activity.TimestampUtc.ToLocalTime():HH:mm:ss} - {activity.Summary}");
    }
}
