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

    Task<IReadOnlyList<LeftoverRemovalResult>> RemoveLeftoversAsync(
        IEnumerable<LeftoverCandidate> leftovers,
        CancellationToken cancellationToken = default);
}
