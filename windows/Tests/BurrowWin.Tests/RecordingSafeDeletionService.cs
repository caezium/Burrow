using BurrowWin.Models;
using BurrowWin.Services;

namespace BurrowWin.Tests;

internal sealed class RecordingSafeDeletionService : ISafeDeletionService
{
    public List<string> DeletedPaths { get; } = [];

    public Task<SafeDeletionResult> DeleteAsync(
        SafeDeletionRequest request,
        CancellationToken cancellationToken = default)
    {
        var authorized = request.Authorization.Authorizes(request.OperationId, request.Candidate);
        var status = cancellationToken.IsCancellationRequested
            ? SafeDeletionStatus.Cancelled
            : authorized && request.FlowValidation.IsAllowed
                ? SafeDeletionStatus.Recycled
                : SafeDeletionStatus.Rejected;
        if (status == SafeDeletionStatus.Recycled)
        {
            DeletedPaths.Add(Path.GetFullPath(request.CanonicalPath));
        }

        var message = status switch
        {
            SafeDeletionStatus.Recycled => "Moved to Recycle Bin.",
            SafeDeletionStatus.Cancelled => "Cancellation requested before recycling.",
            _ => request.FlowValidation.Message
        };
        var now = DateTimeOffset.UtcNow;
        var receipt = new DeletionReceipt(
            Guid.NewGuid().ToString("N"),
            request.OperationId,
            request.Candidate.OriginalPath,
            request.CanonicalPath,
            request.Candidate.ItemType,
            request.Candidate.ExpectedSizeBytes,
            request.FlowValidation.ObservedSizeBytes,
            status,
            now,
            status == SafeDeletionStatus.Recycled ? now : null,
            null,
            false,
            status is SafeDeletionStatus.Rejected or SafeDeletionStatus.Cancelled ? message : null,
            request.Candidate.SourceFlow,
            request.Candidate.CandidateCategory);
        return Task.FromResult(new SafeDeletionResult(
            request.Candidate.OriginalPath,
            request.CanonicalPath,
            status,
            message,
            request.Candidate.ExpectedSizeBytes,
            request.FlowValidation.ObservedSizeBytes,
            receipt));
    }
}
