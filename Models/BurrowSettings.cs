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

    public bool TrayIconEnabled { get; set; } = true;

    public bool McpDestructiveActionsEnabled { get; set; }

    public static BurrowSettings Normalize(BurrowSettings? settings)
    {
        settings ??= new BurrowSettings();
        return new BurrowSettings
        {
            SamplingIntervalSeconds = Math.Clamp(settings.SamplingIntervalSeconds, 5, 300),
            HistoryRetentionDays = Math.Clamp(settings.HistoryRetentionDays, 1, 365),
            HttpServerEnabled = settings.HttpServerEnabled,
            HttpServerPort = Math.Clamp(settings.HttpServerPort, 1024, 65535),
            TrayIconEnabled = settings.TrayIconEnabled,
            McpDestructiveActionsEnabled = settings.McpDestructiveActionsEnabled
        };
    }
}
