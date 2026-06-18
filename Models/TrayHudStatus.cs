namespace BurrowWin.Models;

public sealed record TrayHudStatus(
    string SampleText,
    string HealthScore,
    string HealthLabel,
    string CpuText,
    string MemoryText,
    string DiskText,
    string NetworkText,
    string ActivityTitle,
    string ActivityDetail,
    IReadOnlyList<ProcessTelemetry> TopProcesses);
