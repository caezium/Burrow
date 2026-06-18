using BurrowWin.Models;

namespace BurrowWin.Services;

public static class TrayIconTextFormatter
{
    private const int NotifyIconTextLimit = 63;

    public static string BuildTooltip(SystemTelemetrySnapshot? snapshot)
    {
        if (snapshot is null)
        {
            return "BurrowWin - warming up";
        }

        var text = $"BurrowWin CPU {snapshot.CpuUsagePercent:0}% MEM {snapshot.MemoryUsagePercent:0}%";
        return text.Length <= NotifyIconTextLimit ? text : text[..NotifyIconTextLimit];
    }

    public static string BuildHealthLine(SystemTelemetrySnapshot? snapshot)
    {
        if (snapshot is null)
        {
            return "Health pending";
        }

        var pressure = Math.Max(snapshot.CpuUsagePercent, Math.Max(snapshot.MemoryUsagePercent, snapshot.DiskUsagePercent));
        var score = Math.Clamp(100 - (int)Math.Round(pressure / 2), 0, 100);
        var label = score >= 80 ? "Good" : score >= 60 ? "Watch" : "Busy";
        return $"Health {score} - {label}";
    }

    public static string BuildResourceLine(SystemTelemetrySnapshot? snapshot)
    {
        if (snapshot is null)
        {
            return "CPU --  Memory --  Disk --";
        }

        return $"CPU {snapshot.CpuUsagePercent:0}%  Memory {snapshot.MemoryUsagePercent:0}%  Disk {snapshot.DiskUsagePercent:0}%";
    }

    public static string BuildNetworkLine(SystemTelemetrySnapshot? snapshot)
    {
        if (snapshot is null)
        {
            return "Network --";
        }

        var received = SystemTelemetryFormatter.Rate(snapshot.NetworkReceivedBytesPerSecond);
        var sent = SystemTelemetryFormatter.Rate(snapshot.NetworkSentBytesPerSecond);
        return $"Network {received} down / {sent} up";
    }

    public static string BuildSampleLine(SystemTelemetrySnapshot? snapshot)
    {
        if (snapshot is null)
        {
            return "No telemetry sample yet";
        }

        return $"Latest sample {snapshot.CapturedAt.ToLocalTime():HH:mm:ss}";
    }
}
