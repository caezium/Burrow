using BurrowWin.Models;

namespace BurrowWin.Services;

public interface IPurgeArtifactService
{
    Task<IReadOnlyList<PurgeProjectCandidate>> PreviewAsync(
        IReadOnlyList<string>? searchRoots = null,
        CancellationToken cancellationToken = default);

    ConfirmedDeletionAuthorization ConfirmRemoval(IReadOnlyList<PurgeProjectCandidate> projects);

    Task<DeletionBatchResult> RemoveAsync(
        IReadOnlyList<PurgeProjectCandidate> projects,
        ConfirmedDeletionAuthorization authorization,
        IProgress<DeletionProgress>? progress = null,
        CancellationToken cancellationToken = default);
}
