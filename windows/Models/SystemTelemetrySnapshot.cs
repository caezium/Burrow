using System.Globalization;
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

    public double? GpuUsagePercent { get; init; }

    public string? GpuUnavailableReason { get; init; }

    [JsonIgnore]
    public double? EffectiveGpuUsagePercent
    {
        get
        {
            if (GpuUsagePercent.HasValue)
            {
                return double.IsFinite(GpuUsagePercent.Value)
                    ? Math.Clamp(GpuUsagePercent.Value, 0, 100)
                    : null;
            }

            if (string.IsNullOrWhiteSpace(GpuStatus) ||
                string.Equals(GpuStatus, "Unavailable", StringComparison.OrdinalIgnoreCase))
            {
                return null;
            }

            var percentMarker = GpuStatus.LastIndexOf('%');
            if (percentMarker < 0)
            {
                return null;
            }

            var numericEnd = percentMarker;
            while (numericEnd > 0 && char.IsWhiteSpace(GpuStatus[numericEnd - 1]))
            {
                numericEnd--;
            }

            var numericStart = numericEnd;
            while (numericStart > 0 &&
                (char.IsDigit(GpuStatus[numericStart - 1]) ||
                 GpuStatus[numericStart - 1] is '.' or '-' or '+'))
            {
                numericStart--;
            }

            var numeric = GpuStatus[numericStart..numericEnd];
            return double.TryParse(numeric, NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed)
                ? Math.Clamp(parsed, 0, 100)
                : null;
        }
    }

    [JsonIgnore]
    public bool IsGpuAvailable => EffectiveGpuUsagePercent.HasValue;

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
            [])
        {
            GpuUnavailableReason = "GPU telemetry has not been sampled."
        };
    }
}
