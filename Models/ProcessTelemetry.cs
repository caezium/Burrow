using BurrowWin.Services;

namespace BurrowWin.Models;

public sealed record ProcessTelemetry(
    string Name,
    int ProcessId,
    long WorkingSetBytes,
    double CpuUsagePercent = 0,
    double TotalProcessorSeconds = 0)
{
    public string WorkingSetText => SystemTelemetryFormatter.Bytes(WorkingSetBytes);

    public string CpuUsageText => SystemTelemetryFormatter.Percent(CpuUsagePercent);

    public double CpuBarWidth => Math.Clamp(CpuUsagePercent, 0, 100) / 100 * 88;

    public string PowerImpactText => "-";
}
