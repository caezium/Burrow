using BurrowWin.Models;

namespace BurrowWin.Services;

public interface IMoleEngineService
{
    MoleEngineAvailability GetAvailability();

    Task<MoleCommandResult> ExecuteCommandAsync(
        string arguments,
        Action<string>? onProgress = null,
        CancellationToken cancellationToken = default);

    Task<MoleCommandResult> ExecuteAsync(
        IReadOnlyList<string> arguments,
        Action<string>? onProgress = null,
        CancellationToken cancellationToken = default);
}
