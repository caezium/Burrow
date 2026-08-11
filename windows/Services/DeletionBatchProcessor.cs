using BurrowWin.Models;

namespace BurrowWin.Services;

internal static class DeletionBatchProcessor
{
    public static async Task<DeletionBatchResult> RunAsync<T>(
        IReadOnlyList<T> items,
        string operationId,
        Func<T, string> getPath,
        Func<T, Task<SafeDeletionResult>> processAsync,
        IProgress<DeletionProgress>? progress,
        CancellationToken cancellationToken)
    {
        var results = new List<SafeDeletionResult>(items.Count);
        string? currentOrLastPath = null;
        string? cancellationPath = null;
        var cancelled = false;

        Report(progress, items.Count, results, null, cancelled: false);
        foreach (var item in items)
        {
            var path = getPath(item);
            if (cancellationToken.IsCancellationRequested)
            {
                cancelled = true;
                cancellationPath = path;
                break;
            }

            currentOrLastPath = path;
            var result = await processAsync(item).ConfigureAwait(false);
            results.Add(result);
            var cancelledAfterItem = cancellationToken.IsCancellationRequested ||
                                     result.Status == SafeDeletionStatus.Cancelled;
            Report(progress, items.Count, results, path, cancelledAfterItem);

            if (cancelledAfterItem)
            {
                cancelled = true;
                cancellationPath = path;
                break;
            }
        }

        var batch = BuildResult(items.Count, results, cancelled, currentOrLastPath, cancellationPath, operationId);
        Report(progress, items.Count, results, cancellationPath ?? currentOrLastPath, batch.Cancelled);
        return batch;
    }

    private static DeletionBatchResult BuildResult(
        int total,
        IReadOnlyList<SafeDeletionResult> results,
        bool cancelled,
        string? currentOrLastPath,
        string? cancellationPath,
        string operationId)
    {
        var processed = results.Count(result => result.Status != SafeDeletionStatus.Cancelled);
        var recycled = results.Count(result => result.Status == SafeDeletionStatus.Recycled);
        var absent = results.Count(result => result.Status == SafeDeletionStatus.AlreadyAbsent);
        var rejected = results.Count(result => result.Status == SafeDeletionStatus.Rejected);
        var failed = results.Count(result => result.Status == SafeDeletionStatus.Failed);
        var processedBytes = results
            .Where(result => result.Status != SafeDeletionStatus.Cancelled)
            .Sum(result => Math.Max(0, result.ObservedSizeBytes ?? 0));
        var recycledBytes = results.Sum(result => result.RecycledBytes);

        var outcome = cancelled
            ? DeletionBatchOutcome.Cancelled
            : rejected + failed == 0 && processed == total
                ? DeletionBatchOutcome.Success
                : recycled + absent > 0
                    ? DeletionBatchOutcome.PartialSuccess
                    : DeletionBatchOutcome.Failed;
        var percent = CompletionPercent(total, processed, rejected, failed, cancelled);

        return new DeletionBatchResult(
            results,
            total,
            processed,
            recycled,
            absent,
            rejected,
            failed,
            cancelled,
            processedBytes,
            recycledBytes,
            currentOrLastPath,
            cancellationPath,
            outcome,
            percent,
            operationId);
    }

    private static void Report(
        IProgress<DeletionProgress>? progress,
        int total,
        IReadOnlyList<SafeDeletionResult> results,
        string? currentPath,
        bool cancelled)
    {
        if (progress is null)
        {
            return;
        }

        var processed = results.Count(result => result.Status != SafeDeletionStatus.Cancelled);
        var rejected = results.Count(result => result.Status == SafeDeletionStatus.Rejected);
        var failed = results.Count(result => result.Status == SafeDeletionStatus.Failed);
        progress.Report(new DeletionProgress(
            total,
            processed,
            results.Count(result => result.Status == SafeDeletionStatus.Recycled),
            results.Count(result => result.Status == SafeDeletionStatus.AlreadyAbsent),
            rejected,
            failed,
            results.Where(result => result.Status != SafeDeletionStatus.Cancelled)
                .Sum(result => Math.Max(0, result.ObservedSizeBytes ?? 0)),
            results.Sum(result => result.RecycledBytes),
            currentPath,
            false,
            CompletionPercent(total, processed, rejected, failed, cancelled)));
    }

    private static int CompletionPercent(int total, int processed, int rejected, int failed, bool cancelled)
    {
        if (total <= 0)
        {
            return 0;
        }

        var raw = Math.Clamp((int)Math.Floor(processed * 100d / total), 0, 100);
        return cancelled || rejected + failed > 0 ? Math.Min(99, raw) : raw;
    }
}
