using BurrowWin.Models;

namespace BurrowWin.Services;

public interface ISystemTelemetrySamplerService
{
    TimeSpan SamplingInterval { get; }

    string Source { get; }

    SystemTelemetrySnapshot? LatestSnapshot { get; }

    Task<SystemTelemetrySnapshot> SampleNowAsync(CancellationToken cancellationToken = default);
}
