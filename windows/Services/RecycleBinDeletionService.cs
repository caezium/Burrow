using BurrowWin.Models;

namespace BurrowWin.Services;

public sealed class RecycleBinDeletionService : ISafeDeletionService
{
    private readonly IWindowsPathSafetyPolicy _pathSafetyPolicy;
    private readonly IWindowsFileSystemInspector _fileSystem;
    private readonly IRecycleBinAdapter _recycleBin;
    private readonly IDeletionReceiptStore _receiptStore;

    public RecycleBinDeletionService()
        : this(
            new WindowsPathSafetyPolicy(),
            new WindowsFileSystemInspector(),
            new WindowsShellRecycleBinAdapter(),
            new JsonDeletionReceiptStore())
    {
    }

    public RecycleBinDeletionService(
        IWindowsPathSafetyPolicy pathSafetyPolicy,
        IWindowsFileSystemInspector fileSystem,
        IRecycleBinAdapter recycleBin,
        IDeletionReceiptStore receiptStore)
    {
        _pathSafetyPolicy = pathSafetyPolicy;
        _fileSystem = fileSystem;
        _recycleBin = recycleBin;
        _receiptStore = receiptStore;
    }

    public async Task<SafeDeletionResult> DeleteAsync(
        SafeDeletionRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        var candidate = request.Candidate;

        if (!request.Authorization.Authorizes(request.OperationId, candidate))
        {
            return await CompleteAsync(request, null, SafeDeletionStatus.Rejected,
                "Explicit confirmation does not authorize this exact candidate.", null).ConfigureAwait(false);
        }

        var safety = _pathSafetyPolicy.Validate(candidate.OriginalPath, candidate.ExpectedScopeRoot);
        if (!safety.IsSafe)
        {
            return await CompleteAsync(request, safety.CanonicalPath, SafeDeletionStatus.Rejected,
                safety.Message, null).ConfigureAwait(false);
        }

        if (!string.Equals(safety.CanonicalPath, request.CanonicalPath, StringComparison.OrdinalIgnoreCase))
        {
            return await CompleteAsync(request, safety.CanonicalPath, SafeDeletionStatus.Rejected,
                "The canonical target changed after preview.", null).ConfigureAwait(false);
        }

        if (!request.FlowValidation.IsAllowed)
        {
            return await CompleteAsync(request, safety.CanonicalPath, SafeDeletionStatus.Rejected,
                request.FlowValidation.Message, request.FlowValidation.ObservedSizeBytes).ConfigureAwait(false);
        }

        var target = safety.TargetInfo ?? _fileSystem.Inspect(safety.CanonicalPath!);
        if (!target.Exists)
        {
            return await CompleteAsync(request, safety.CanonicalPath, SafeDeletionStatus.AlreadyAbsent,
                "Path was already absent; no item was removed and no bytes were freed.", null).ConfigureAwait(false);
        }

        if (target.ItemType != candidate.ItemType)
        {
            return await CompleteAsync(request, safety.CanonicalPath, SafeDeletionStatus.Rejected,
                "The candidate type changed after preview.", target.SizeBytes).ConfigureAwait(false);
        }

        if (cancellationToken.IsCancellationRequested)
        {
            return await CompleteAsync(request, safety.CanonicalPath, SafeDeletionStatus.Cancelled,
                "Cancellation was requested before the Recycle Bin operation started.",
                request.FlowValidation.ObservedSizeBytes ?? target.SizeBytes).ConfigureAwait(false);
        }

        // Final fail-closed validation immediately before handing the path to the Shell.
        var finalSafety = _pathSafetyPolicy.Validate(candidate.OriginalPath, candidate.ExpectedScopeRoot);
        if (!finalSafety.IsSafe ||
            !string.Equals(finalSafety.CanonicalPath, request.CanonicalPath, StringComparison.OrdinalIgnoreCase))
        {
            return await CompleteAsync(request, finalSafety.CanonicalPath, SafeDeletionStatus.Rejected,
                finalSafety.IsSafe ? "The canonical target changed immediately before deletion." : finalSafety.Message,
                request.FlowValidation.ObservedSizeBytes).ConfigureAwait(false);
        }

        var finalTarget = finalSafety.TargetInfo ?? _fileSystem.Inspect(finalSafety.CanonicalPath!);
        if (!finalTarget.Exists)
        {
            return await CompleteAsync(request, finalSafety.CanonicalPath, SafeDeletionStatus.AlreadyAbsent,
                "Path became absent before deletion; no item was removed and no bytes were freed.", null).ConfigureAwait(false);
        }

        if (finalTarget.ItemType != candidate.ItemType)
        {
            return await CompleteAsync(request, finalSafety.CanonicalPath, SafeDeletionStatus.Rejected,
                "The candidate type changed immediately before deletion.", finalTarget.SizeBytes).ConfigureAwait(false);
        }

        long finalObservedSize;
        try
        {
            if (!_fileSystem.TryMeasureSize(finalSafety.CanonicalPath!, cancellationToken, out finalObservedSize))
            {
                return await CompleteAsync(request, finalSafety.CanonicalPath, SafeDeletionStatus.Rejected,
                    "The candidate could not be measured safely immediately before deletion.",
                    finalTarget.SizeBytes).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException)
        {
            return await CompleteAsync(request, finalSafety.CanonicalPath, SafeDeletionStatus.Cancelled,
                "Cancellation was requested while performing final candidate validation.",
                finalTarget.SizeBytes).ConfigureAwait(false);
        }

        var latestSafety = _pathSafetyPolicy.Validate(candidate.OriginalPath, candidate.ExpectedScopeRoot);
        if (!latestSafety.IsSafe ||
            !string.Equals(latestSafety.CanonicalPath, request.CanonicalPath, StringComparison.OrdinalIgnoreCase))
        {
            return await CompleteAsync(request, latestSafety.CanonicalPath, SafeDeletionStatus.Rejected,
                latestSafety.IsSafe ? "The canonical target changed during final validation." : latestSafety.Message,
                finalObservedSize).ConfigureAwait(false);
        }

        var latestTarget = latestSafety.TargetInfo ?? _fileSystem.Inspect(finalSafety.CanonicalPath!);
        if (!latestTarget.Exists)
        {
            return await CompleteAsync(request, finalSafety.CanonicalPath, SafeDeletionStatus.AlreadyAbsent,
                "Path became absent during final validation; no item was removed and no bytes were freed.", null).ConfigureAwait(false);
        }

        if (latestTarget.IsReparsePoint || latestTarget.ItemType != candidate.ItemType)
        {
            return await CompleteAsync(request, finalSafety.CanonicalPath, SafeDeletionStatus.Rejected,
                "The candidate type or reparse state changed immediately before deletion.",
                latestTarget.SizeBytes).ConfigureAwait(false);
        }

        if (request.FlowValidation.ObservedSizeBytes.HasValue &&
            finalObservedSize != request.FlowValidation.ObservedSizeBytes.Value)
        {
            return await CompleteAsync(request, finalSafety.CanonicalPath, SafeDeletionStatus.Rejected,
                "The candidate changed immediately before deletion; rescan before removal.",
                finalObservedSize).ConfigureAwait(false);
        }

        if (candidate.PreviewLastWriteTimeUtc.HasValue &&
            latestTarget.LastWriteTimeUtc?.UtcDateTime != candidate.PreviewLastWriteTimeUtc.Value.UtcDateTime)
        {
            return await CompleteAsync(request, finalSafety.CanonicalPath, SafeDeletionStatus.Rejected,
                "The candidate timestamp changed immediately before deletion; rescan before removal.",
                finalObservedSize).ConfigureAwait(false);
        }

        if (cancellationToken.IsCancellationRequested)
        {
            return await CompleteAsync(request, finalSafety.CanonicalPath, SafeDeletionStatus.Cancelled,
                "Cancellation was requested before the Recycle Bin operation started.",
                finalObservedSize).ConfigureAwait(false);
        }

        RecycleBinAdapterResult backendResult;
        try
        {
            // Intentionally not cancellable once started: wait for the observable Shell outcome,
            // then the batch stops before scheduling any later target.
            backendResult = await _recycleBin.RecycleAsync(finalSafety.CanonicalPath!, candidate.ItemType)
                .ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            backendResult = new RecycleBinAdapterResult(false, ex.Message);
        }

        var status = backendResult.Succeeded ? SafeDeletionStatus.Recycled : SafeDeletionStatus.Failed;
        return await CompleteAsync(
            request,
            finalSafety.CanonicalPath,
            status,
            backendResult.Message,
            finalObservedSize,
            backendResult.RecoveryLocator,
            backendResult.ExactRecoveryLocatorAvailable).ConfigureAwait(false);
    }

    private async Task<SafeDeletionResult> CompleteAsync(
        SafeDeletionRequest request,
        string? canonicalPath,
        SafeDeletionStatus status,
        string message,
        long? observedSizeBytes,
        string? recoveryLocator = null,
        bool exactRecoveryLocatorAvailable = false)
    {
        var recordedAt = DateTimeOffset.UtcNow;
        var receipt = new DeletionReceipt(
            Guid.NewGuid().ToString("N"),
            request.OperationId,
            request.Candidate.OriginalPath,
            canonicalPath,
            request.Candidate.ItemType,
            request.Candidate.ExpectedSizeBytes,
            observedSizeBytes,
            status,
            recordedAt,
            status == SafeDeletionStatus.Recycled ? recordedAt : null,
            recoveryLocator,
            exactRecoveryLocatorAvailable,
            status is SafeDeletionStatus.Rejected or SafeDeletionStatus.Failed or SafeDeletionStatus.Cancelled ? message : null,
            request.Candidate.SourceFlow,
            request.Candidate.CandidateCategory);

        try
        {
            await _receiptStore.AppendAsync(receipt, CancellationToken.None).ConfigureAwait(false);
            return new SafeDeletionResult(
                request.Candidate.OriginalPath,
                canonicalPath,
                status,
                message,
                request.Candidate.ExpectedSizeBytes,
                observedSizeBytes,
                receipt);
        }
        catch (Exception ex)
        {
            return new SafeDeletionResult(
                request.Candidate.OriginalPath,
                canonicalPath,
                status,
                $"{message} Receipt persistence failed: {ex.Message}",
                request.Candidate.ExpectedSizeBytes,
                observedSizeBytes,
                receipt,
                false,
                ex.Message);
        }
    }
}
