using BurrowWin.Models;

namespace BurrowWin.Services;

public interface IInstalledApplicationService
{
    Task<IReadOnlyList<InstalledApplication>> GetInstalledApplicationsAsync(CancellationToken cancellationToken = default);

    Task<IReadOnlyList<LeftoverCandidate>> PreviewLeftoversAsync(
        InstalledApplication application,
        CancellationToken cancellationToken = default);

    Task<MoleCommandResult> LaunchUninstallerAsync(
        InstalledApplication application,
        CancellationToken cancellationToken = default);

    ConfirmedDeletionAuthorization ConfirmLeftoverRemoval(IReadOnlyList<LeftoverCandidate> leftovers);

    Task<DeletionBatchResult> RemoveLeftoversAsync(
        IReadOnlyList<LeftoverCandidate> leftovers,
        ConfirmedDeletionAuthorization authorization,
        IProgress<DeletionProgress>? progress = null,
        CancellationToken cancellationToken = default);
}
