using BurrowWin.Models;

namespace BurrowWin.Services;

public interface IOperationHistoryService
{
    string HistoryFilePath { get; }

    Task RecordAsync(OperationHistoryEntry entry, CancellationToken cancellationToken = default);

    Task<IReadOnlyList<OperationHistoryEntry>> ReadRecentAsync(int limit, CancellationToken cancellationToken = default);
}
