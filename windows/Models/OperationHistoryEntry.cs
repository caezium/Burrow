using System.Text.Json.Serialization;

namespace BurrowWin.Models;

public sealed record OperationHistoryEntry(
    DateTimeOffset TimestampUtc,
    string Source,
    string Operation,
    string Arguments,
    int ExitCode,
    bool Succeeded,
    long DurationMs,
    string Summary,
    DeletionBatchOutcome? BatchOutcome = null,
    string? OperationId = null,
    int RecycledCount = 0,
    int AlreadyAbsentCount = 0,
    int RejectedCount = 0,
    int FailedCount = 0,
    int ProcessedCount = 0,
    int TotalSelectedItems = 0,
    long RecycledBytes = 0,
    bool Cancelled = false)
{
    [JsonIgnore]
    public string TimestampText => TimestampUtc.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss");

    [JsonIgnore]
    public string ResultText => BatchOutcome.HasValue
        ? $"{BatchOutcome.Value} ({ExitCode})"
        : Succeeded ? $"Succeeded ({ExitCode})" : $"Failed ({ExitCode})";
}
