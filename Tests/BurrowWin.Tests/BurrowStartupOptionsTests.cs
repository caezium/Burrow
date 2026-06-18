using BurrowWin.Services;
using Xunit;

namespace BurrowWin.Tests;

public sealed class BurrowStartupOptionsTests
{
    [Fact]
    public void Parse_DefaultsToNormalStartup()
    {
        var options = BurrowStartupOptions.Parse(null, _ => null);

        Assert.False(options.ShowTrayHudDiagnostic);
        Assert.False(options.DisableTray);
        Assert.Null(options.InitialRoute);
    }

    [Fact]
    public void Parse_ReadsDiagnosticFlagsFromArguments()
    {
        var options = BurrowStartupOptions.Parse("--show-tray-hud --no-tray", _ => null);

        Assert.True(options.ShowTrayHudDiagnostic);
        Assert.True(options.DisableTray);
    }

    [Fact]
    public void Parse_ReadsDiagnosticFlagsFromEnvironment()
    {
        var values = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase)
        {
            ["BURROWWIN_SHOW_TRAY_HUD"] = "true",
            ["BURROWWIN_DISABLE_TRAY"] = "1",
            ["BURROWWIN_START_ROUTE"] = "purge"
        };

        var options = BurrowStartupOptions.Parse(string.Empty, name => values.GetValueOrDefault(name));

        Assert.True(options.ShowTrayHudDiagnostic);
        Assert.True(options.DisableTray);
        Assert.Equal("purge", options.InitialRoute);
    }

    [Fact]
    public void Parse_ReadsInitialRouteFromArguments()
    {
        var options = BurrowStartupOptions.Parse("--route=history", _ => null);

        Assert.Equal("history", options.InitialRoute);
    }
}
