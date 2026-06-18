using System.Text.Json.Serialization;

namespace BurrowWin.Models;

public sealed record SystemTelemetrySnapshot(
    DateTimeOffset CapturedAt,
    double CpuUsagePercent,
    double MemoryUsagePercent,
    long MemoryUsedBytes,
    long MemoryTotalBytes,
    double DiskUsagePercent,
    long DiskUsedBytes,
    long DiskTotalBytes,
    double NetworkReceivedBytesPerSecond,
    double NetworkSentBytesPerSecond,
    string GpuStatus,
    IReadOnlyList<ProcessTelemetry> TopProcesses)
{
    public string NetworkInterfaceName { get; init; } = "network";

    public string NetworkIPv4Address { get; init; } = "unavailable";

    public double? BatteryChargePercent { get; init; }

    public string BatteryStatusText { get; init; } = "unavailable";

    public string BatteryHealthText { get; init; } = "Unavailable";

    public int? BatteryEstimatedSecondsRemaining { get; init; }

    public bool HasBattery { get; init; }

    [JsonIgnore]
    public string TimestampText => CapturedAt.ToLocalTime().ToString("HH:mm:ss");

    [JsonIgnore]
    public string CpuText => $"{CpuUsagePercent:0.0}%";

    [JsonIgnore]
    public string MemoryText => $"{MemoryUsagePercent:0.0}%";

    [JsonIgnore]
    public string DiskText => $"{DiskUsagePercent:0.0}%";

    public static SystemTelemetrySnapshot Empty(DateTimeOffset capturedAt)
    {
        return new SystemTelemetrySnapshot(
            capturedAt,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            "Unavailable",
            []);
    }
}
