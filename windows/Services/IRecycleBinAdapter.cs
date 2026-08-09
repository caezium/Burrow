using BurrowWin.Models;

namespace BurrowWin.Services;

public sealed record RecycleBinAdapterResult(
    bool Succeeded,
    string Message,
    string? RecoveryLocator = null,
    bool ExactRecoveryLocatorAvailable = false);

public interface IRecycleBinAdapter
{
    Task<RecycleBinAdapterResult> RecycleAsync(string canonicalPath, DeletionItemType itemType);
}
