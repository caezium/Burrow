using BurrowWin.Services;

namespace BurrowWin.Models;

public sealed record ProcessUsageSummary(
    string Name,
    int ProcessId,
    int SampleCount,
    long PeakWorkingSetBytes,
    double AverageWorkingSetBytes,
    double PeakCpuUsagePercent,
    double AverageCpuUsagePercent,
    double TotalProcessorSeconds)
{
    public string PeakWorkingSetText => SystemTelemetryFormatter.Bytes(PeakWorkingSetBytes);

    public string AverageWorkingSetText => SystemTelemetryFormatter.Bytes((long)AverageWorkingSetBytes);

    public string PeakCpuUsageText => SystemTelemetryFormatter.Percent(PeakCpuUsagePercent);

    public string AverageCpuUsageText => SystemTelemetryFormatter.Percent(AverageCpuUsagePercent);
}
