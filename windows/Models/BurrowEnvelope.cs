using System.Text.Json;
using System.Text.Json.Serialization;

namespace BurrowWin.Models;

/// <summary>
/// The unified result envelope that burrow-cli (<c>burrow.exe</c>) writes to stdout
/// for every command. Success and failure share ONE shape — branch on <see cref="Ok"/>,
/// then read <see cref="Data"/> (success) or <see cref="Error"/> (failure).
/// Contract: caezium/burrow-cli#4.
/// </summary>
public sealed record BurrowEnvelope
{
    [JsonPropertyName("ok")]
    public bool Ok { get; init; }

    [JsonPropertyName("command")]
    public string? Command { get; init; }

    [JsonPropertyName("burrow_cli")]
    public string? BurrowCli { get; init; }

    /// <summary>The engine payload on success (absent/undefined on failure).</summary>
    [JsonPropertyName("data")]
    public JsonElement Data { get; init; }

    /// <summary>The error message on failure (null on success).</summary>
    [JsonPropertyName("error")]
    public string? Error { get; init; }

    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNameCaseInsensitive = true,
    };

    /// <summary>
    /// Parse <c>burrow.exe</c> stdout into an envelope.
    /// Throws <see cref="JsonException"/> on non-JSON / empty output.
    /// </summary>
    public static BurrowEnvelope Parse(string stdout)
        => JsonSerializer.Deserialize<BurrowEnvelope>(stdout, Options)
           ?? throw new JsonException("empty burrow envelope");
}
