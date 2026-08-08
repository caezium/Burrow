using System.Security.Cryptography;

namespace BurrowWin.Models;

public sealed class BurrowSettings
{
    public const int DefaultSamplingIntervalSeconds = 60;
    public const int DefaultHistoryRetentionDays = 90;
    public const int DefaultHttpServerPort = 9277;

    public int SamplingIntervalSeconds { get; set; } = DefaultSamplingIntervalSeconds;

    public int HistoryRetentionDays { get; set; } = DefaultHistoryRetentionDays;

    public bool HttpServerEnabled { get; set; } = true;

    public int HttpServerPort { get; set; } = DefaultHttpServerPort;

    /// Per-install bearer credential for the loopback HTTP/MCP surface. The
    /// stdio bridge reads the same user-private settings file and sends it in
    /// an Authorization header; browsers and unrelated callers do not know it.
    public string HttpServerAuthToken { get; set; } = CreateHttpServerAuthToken();

    public bool TrayIconEnabled { get; set; } = true;

    public bool McpDestructiveActionsEnabled { get; set; }

    /// Share anonymous crash reports + usage analytics. Opt-out (on by default),
    /// matching the macOS app; see Services/AppTelemetry.cs.
    public bool TelemetryEnabled { get; set; } = true;

    public static BurrowSettings Normalize(BurrowSettings? settings)
    {
        settings ??= new BurrowSettings();
        return new BurrowSettings
        {
            SamplingIntervalSeconds = Math.Clamp(settings.SamplingIntervalSeconds, 5, 300),
            HistoryRetentionDays = Math.Clamp(settings.HistoryRetentionDays, 1, 365),
            HttpServerEnabled = settings.HttpServerEnabled,
            HttpServerPort = Math.Clamp(settings.HttpServerPort, 1024, 65535),
            HttpServerAuthToken = IsValidHttpServerAuthToken(settings.HttpServerAuthToken)
                ? settings.HttpServerAuthToken
                : CreateHttpServerAuthToken(),
            TrayIconEnabled = settings.TrayIconEnabled,
            McpDestructiveActionsEnabled = settings.McpDestructiveActionsEnabled,
            TelemetryEnabled = settings.TelemetryEnabled
        };
    }

    internal static string CreateHttpServerAuthToken()
    {
        return Convert.ToBase64String(RandomNumberGenerator.GetBytes(32))
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');
    }

    internal static bool IsValidHttpServerAuthToken(string? token)
    {
        return token is { Length: >= 43 } && token.All(character =>
            char.IsAsciiLetterOrDigit(character) || character is '-' or '_');
    }
}
