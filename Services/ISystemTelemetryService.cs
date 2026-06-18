using BurrowWin.Models;

namespace BurrowWin.Services;

public interface ISystemTelemetryService
{
    Task<SystemTelemetrySnapshot> CaptureAsync(CancellationToken cancellationToken = default);
}
