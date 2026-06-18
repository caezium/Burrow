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
    string Summary)
{
    [JsonIgnore]
    public string TimestampText => TimestampUtc.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss");

    [JsonIgnore]
    public string ResultText => Succeeded ? $"Succeeded ({ExitCode})" : $"Failed ({ExitCode})";
}
