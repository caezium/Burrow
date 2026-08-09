using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Serialization;

namespace BurrowWin.Models;

public enum DestructiveFlow
{
    Purge,
    Installer,
    UninstallLeftovers
}

public enum DeletionItemType
{
    File,
    Directory
}

public enum SafeDeletionStatus
{
    Recycled,
    AlreadyAbsent,
    Rejected,
    Failed,
    Cancelled
}

public enum DeletionBatchOutcome
{
    Success,
    PartialSuccess,
    Failed,
    Cancelled
}

public sealed record DeletionCandidateDescriptor(
    string OriginalPath,
    string ExpectedScopeRoot,
    DestructiveFlow SourceFlow,
    string CandidateCategory,
    DeletionItemType ItemType,
    long ExpectedSizeBytes,
    DateTimeOffset? PreviewLastWriteTimeUtc = null)
{
    internal string Fingerprint()
    {
        var normalized = string.Join("\n",
        [
            (OriginalPath ?? string.Empty).Trim().ToUpperInvariant(),
            (ExpectedScopeRoot ?? string.Empty).Trim().ToUpperInvariant(),
            SourceFlow.ToString(),
            (CandidateCategory ?? string.Empty).Trim().ToUpperInvariant(),
            ItemType.ToString(),
            ExpectedSizeBytes.ToString(System.Globalization.CultureInfo.InvariantCulture),
            PreviewLastWriteTimeUtc?.UtcDateTime.Ticks.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? string.Empty
        ]);
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(normalized)));
    }
}

/// <summary>
/// Immutable evidence that a specific candidate set was confirmed by the UI.
/// The type is deliberately non-defaultable and binds both the operation and every candidate.
/// </summary>
public sealed class ConfirmedDeletionAuthorization
{
    private readonly HashSet<string> _candidateFingerprints;

    private ConfirmedDeletionAuthorization(
        string operationId,
        DestructiveFlow sourceFlow,
        DateTimeOffset confirmedAtUtc,
        HashSet<string> candidateFingerprints,
        string candidateSetHash)
    {
        OperationId = operationId;
        SourceFlow = sourceFlow;
        ConfirmedAtUtc = confirmedAtUtc;
        _candidateFingerprints = candidateFingerprints;
        CandidateSetHash = candidateSetHash;
    }

    public string OperationId { get; }

    public DestructiveFlow SourceFlow { get; }

    public DateTimeOffset ConfirmedAtUtc { get; }

    public string CandidateSetHash { get; }

    public int CandidateCount => _candidateFingerprints.Count;

    public static ConfirmedDeletionAuthorization Confirm(
        DestructiveFlow sourceFlow,
        IEnumerable<DeletionCandidateDescriptor> candidates,
        string? operationId = null,
        DateTimeOffset? confirmedAtUtc = null)
    {
        ArgumentNullException.ThrowIfNull(candidates);
        var fingerprints = candidates.Select(candidate => candidate.Fingerprint())
            .ToHashSet(StringComparer.Ordinal);
        if (fingerprints.Count == 0)
        {
            throw new ArgumentException("At least one deletion candidate must be confirmed.", nameof(candidates));
        }

        operationId = string.IsNullOrWhiteSpace(operationId)
            ? Guid.NewGuid().ToString("N")
            : operationId.Trim();

        return new ConfirmedDeletionAuthorization(
            operationId,
            sourceFlow,
            confirmedAtUtc ?? DateTimeOffset.UtcNow,
            fingerprints,
            HashCandidateSet(fingerprints));
    }

    public bool Authorizes(string operationId, DeletionCandidateDescriptor candidate)
    {
        return string.Equals(OperationId, operationId, StringComparison.Ordinal) &&
               SourceFlow == candidate.SourceFlow &&
               _candidateFingerprints.Contains(candidate.Fingerprint());
    }

    public bool IsExactMatch(IEnumerable<DeletionCandidateDescriptor> candidates)
    {
        ArgumentNullException.ThrowIfNull(candidates);
        var fingerprints = candidates.Select(candidate => candidate.Fingerprint())
            .ToHashSet(StringComparer.Ordinal);
        return fingerprints.Count == _candidateFingerprints.Count &&
               string.Equals(HashCandidateSet(fingerprints), CandidateSetHash, StringComparison.Ordinal);
    }

    private static string HashCandidateSet(IEnumerable<string> fingerprints)
    {
        var joined = string.Join("\n", fingerprints.Order(StringComparer.Ordinal));
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(joined)));
    }
}

public sealed record FlowSafetyValidation(
    bool IsAllowed,
    string ReasonCode,
    string Message,
    long? ObservedSizeBytes = null)
{
    public static FlowSafetyValidation Allow(long? observedSizeBytes = null) =>
        new(true, "allowed", "Candidate passed flow-specific validation.", observedSizeBytes);

    public static FlowSafetyValidation Reject(string reasonCode, string message) =>
        new(false, reasonCode, message);
}

public sealed record SafeDeletionRequest(
    DeletionCandidateDescriptor Candidate,
    string CanonicalPath,
    string OperationId,
    ConfirmedDeletionAuthorization Authorization,
    FlowSafetyValidation FlowValidation);

public sealed record DeletionReceipt(
    string ReceiptId,
    string OperationId,
    string OriginalPath,
    string? CanonicalPath,
    DeletionItemType ItemType,
    long ExpectedSizeBytes,
    long? ObservedSizeBytes,
    SafeDeletionStatus Disposition,
    DateTimeOffset RecordedAtUtc,
    DateTimeOffset? RecycledAtUtc,
    string? RecoveryLocator,
    bool ExactRecoveryLocatorAvailable,
    string? FailureOrRejectionReason,
    DestructiveFlow SourceFlow,
    string CandidateCategory);

public sealed record SafeDeletionResult(
    string Path,
    string? CanonicalPath,
    SafeDeletionStatus Status,
    string Message,
    long ExpectedSizeBytes,
    long? ObservedSizeBytes,
    DeletionReceipt Receipt,
    bool ReceiptPersisted = true,
    string? ReceiptPersistenceError = null)
{
    [JsonIgnore]
    public bool Succeeded => Status is SafeDeletionStatus.Recycled or SafeDeletionStatus.AlreadyAbsent;

    [JsonIgnore]
    public long RecycledBytes => Status == SafeDeletionStatus.Recycled
        ? Math.Max(0, ObservedSizeBytes ?? ExpectedSizeBytes)
        : 0;
}

public sealed record DeletionProgress(
    int TotalItems,
    int ProcessedCount,
    int RecycledCount,
    int AlreadyAbsentCount,
    int RejectedCount,
    int FailedCount,
    long ProcessedBytes,
    long RecycledBytes,
    string? CurrentPath,
    bool IsIndeterminate,
    int CompletionPercent);

public sealed record DeletionBatchResult(
    IReadOnlyList<SafeDeletionResult> ItemResults,
    int TotalSelectedItems,
    int ProcessedCount,
    int RecycledCount,
    int AlreadyAbsentCount,
    int RejectedCount,
    int FailedCount,
    bool Cancelled,
    long ProcessedBytes,
    long RecycledBytes,
    string? CurrentOrLastProcessedPath,
    string? InProgressPathWhenCancelled,
    DeletionBatchOutcome Outcome,
    int CompletionPercent,
    string OperationId)
{
    public int ExitCode => Outcome switch
    {
        DeletionBatchOutcome.Success => 0,
        DeletionBatchOutcome.Failed => 1,
        DeletionBatchOutcome.PartialSuccess => 2,
        DeletionBatchOutcome.Cancelled => 3,
        _ => 1
    };

    public bool Succeeded => Outcome == DeletionBatchOutcome.Success;
}
