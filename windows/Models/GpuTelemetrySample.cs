using System.Globalization;

namespace BurrowWin.Models;

public sealed record GpuTelemetrySample(
    double? UsagePercent,
    string Status,
    string? UnavailableReason = null,
    DateTimeOffset? RetryAfter = null)
{
    public bool IsAvailable => UsagePercent.HasValue;

    public static GpuTelemetrySample Available(double usagePercent)
    {
        var normalized = double.IsFinite(usagePercent)
            ? Math.Clamp(usagePercent, 0, 100)
            : 0;
        return new GpuTelemetrySample(
            normalized,
            string.Create(CultureInfo.InvariantCulture, $"3D {normalized:0.0}%"));
    }

    public static GpuTelemetrySample Unavailable(string reason)
    {
        return new GpuTelemetrySample(null, "Unavailable", reason);
    }
}
