using BurrowWin.Models;

namespace BurrowWin.Services;

public interface IInstallerCleanupService
{
    Task<IReadOnlyList<InstallerCleanupCandidate>> PreviewAsync(CancellationToken cancellationToken = default);

    Task<IReadOnlyList<LeftoverRemovalResult>> RemoveAsync(
        IReadOnlyList<InstallerCleanupCandidate> candidates,
        CancellationToken cancellationToken = default);
}
