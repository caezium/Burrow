using BurrowWin.Models;
using BurrowWin.Services;
using Xunit;

namespace BurrowWin.Tests;

public sealed class HttpServerSettingsPlannerTests
{
    [Fact]
    public void Plan_ReturnsNone_WhenEnabledPortIsUnchanged()
    {
        var settings = new BurrowSettings
        {
            HttpServerEnabled = true,
            HttpServerPort = 9277
        };

        var action = HttpServerSettingsPlanner.Plan(true, 9277, settings);

        Assert.Equal(HttpServerSettingsAction.None, action);
    }

    [Fact]
    public void Plan_ReturnsStart_WhenInactiveSettingsEnableHttp()
    {
        var settings = new BurrowSettings
        {
            HttpServerEnabled = true,
            HttpServerPort = 9277
        };

        var action = HttpServerSettingsPlanner.Plan(false, 9277, settings);

        Assert.Equal(HttpServerSettingsAction.Start, action);
    }

    [Fact]
    public void Plan_ReturnsStop_WhenActiveSettingsDisableHttp()
    {
        var settings = new BurrowSettings
        {
            HttpServerEnabled = false,
            HttpServerPort = 9277
        };

        var action = HttpServerSettingsPlanner.Plan(true, 9277, settings);

        Assert.Equal(HttpServerSettingsAction.Stop, action);
    }

    [Fact]
    public void Plan_ReturnsRestart_WhenEnabledPortChanges()
    {
        var settings = new BurrowSettings
        {
            HttpServerEnabled = true,
            HttpServerPort = 9444
        };

        var action = HttpServerSettingsPlanner.Plan(true, 9277, settings);

        Assert.Equal(HttpServerSettingsAction.Restart, action);
    }

    [Fact]
    public void Plan_ReturnsNone_WhenInactiveSettingsKeepHttpDisabled()
    {
        var settings = new BurrowSettings
        {
            HttpServerEnabled = false,
            HttpServerPort = 9444
        };

        var action = HttpServerSettingsPlanner.Plan(false, 9277, settings);

        Assert.Equal(HttpServerSettingsAction.None, action);
    }
}
