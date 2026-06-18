using BurrowWin.Models;

namespace BurrowWin.Services;

public enum HttpServerSettingsAction
{
    None,
    Start,
    Stop,
    Restart
}

public static class HttpServerSettingsPlanner
{
    public static HttpServerSettingsAction Plan(
        bool activeHttpEnabled,
        int activePort,
        BurrowSettings settings)
    {
        var normalized = BurrowSettings.Normalize(settings);
        if (!activeHttpEnabled && !normalized.HttpServerEnabled)
        {
            return HttpServerSettingsAction.None;
        }

        if (!activeHttpEnabled)
        {
            return HttpServerSettingsAction.Start;
        }

        if (!normalized.HttpServerEnabled)
        {
            return HttpServerSettingsAction.Stop;
        }

        return activePort == normalized.HttpServerPort
            ? HttpServerSettingsAction.None
            : HttpServerSettingsAction.Restart;
    }
}
