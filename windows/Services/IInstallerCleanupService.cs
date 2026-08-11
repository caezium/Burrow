using BurrowWin.Models;

namespace BurrowWin.Services;

public interface IInstallerCleanupService
{
    Task<IReadOnlyList<InstallerCleanupCandidate>> PreviewAsync(CancellationToken cancellationToken = default);

    ConfirmedDeletionAuthorization ConfirmRemoval(IReadOnlyList<InstallerCleanupCandidate> candidates);

    Task<DeletionBatchResult> RemoveAsync(
        IReadOnlyList<InstallerCleanupCandidate> candidates,
        ConfirmedDeletionAuthorization authorization,
        IProgress<DeletionProgress>? progress = null,
        CancellationToken cancellationToken = default);
}
