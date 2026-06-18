namespace BurrowWin.Services;

public sealed record BurrowStartupOptions(
    bool ShowTrayHudDiagnostic,
    bool DisableTray,
    string? InitialRoute)
{
    public static BurrowStartupOptions FromLaunchArguments(string? arguments)
    {
        return Parse(arguments, Environment.GetEnvironmentVariable);
    }

    public static BurrowStartupOptions Parse(
        string? arguments,
        Func<string, string?> environment)
    {
        var tokens = Tokenize(arguments);
        var showTrayHud = IsEnabled(environment("BURROWWIN_SHOW_TRAY_HUD")) ||
                          tokens.Contains("--show-tray-hud", StringComparer.OrdinalIgnoreCase);
        var disableTray = IsEnabled(environment("BURROWWIN_DISABLE_TRAY")) ||
                          tokens.Contains("--no-tray", StringComparer.OrdinalIgnoreCase);
        var route = ReadOption(tokens, "--route") ?? environment("BURROWWIN_START_ROUTE");

        return new BurrowStartupOptions(showTrayHud, disableTray, NormalizeRoute(route));
    }

    private static bool IsEnabled(string? value)
    {
        return string.Equals(value, "1", StringComparison.OrdinalIgnoreCase) ||
               string.Equals(value, "true", StringComparison.OrdinalIgnoreCase) ||
               string.Equals(value, "yes", StringComparison.OrdinalIgnoreCase);
    }

    private static HashSet<string> Tokenize(string? arguments)
    {
        if (string.IsNullOrWhiteSpace(arguments))
        {
            return new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        }

        return arguments
            .Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
    }

    private static string? ReadOption(HashSet<string> tokens, string name)
    {
        var prefix = name + "=";
        var match = tokens.FirstOrDefault(token => token.StartsWith(prefix, StringComparison.OrdinalIgnoreCase));
        return match is null ? null : match[prefix.Length..];
    }

    private static string? NormalizeRoute(string? route)
    {
        route = route?.Trim();
        if (string.IsNullOrWhiteSpace(route))
        {
            return null;
        }

        return route;
    }
}
