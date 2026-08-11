using BurrowWin.Models;

namespace BurrowWin.Services;

public interface IGpuTelemetryProvider
{
    GpuTelemetrySample Capture();
}
