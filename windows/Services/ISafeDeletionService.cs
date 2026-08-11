using BurrowWin.Models;

namespace BurrowWin.Services;

public interface ISafeDeletionService
{
    Task<SafeDeletionResult> DeleteAsync(
        SafeDeletionRequest request,
        CancellationToken cancellationToken = default);
}
