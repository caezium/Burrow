using BurrowWin.Models;
using BurrowWin.Services;
using Xunit;

namespace BurrowWin.Tests;

public sealed class JsonApplicationSettingsServiceTests : IDisposable
{
    private readonly string _tempRoot = Path.Combine(Path.GetTempPath(), "BurrowWinTests", Guid.NewGuid().ToString("N"));
    private readonly string _settingsPath;

    public JsonApplicationSettingsServiceTests()
    {
        Directory.CreateDirectory(_tempRoot);
        _settingsPath = Path.Combine(_tempRoot, "settings.json");
    }

    [Fact]
    public void Constructor_UsesNormalizedDefaults_WhenFileIsMissing()
    {
        var service = new JsonApplicationSettingsService(_settingsPath);

        Assert.Equal(BurrowSettings.DefaultSamplingIntervalSeconds, service.Current.SamplingIntervalSeconds);
        Assert.Equal(BurrowSettings.DefaultHistoryRetentionDays, service.Current.HistoryRetentionDays);
        Assert.Equal(BurrowSettings.DefaultHttpServerPort, service.Current.HttpServerPort);
        Assert.True(service.Current.HttpServerEnabled);
        Assert.True(service.Current.TrayIconEnabled);
        Assert.False(service.Current.McpDestructiveActionsEnabled);
    }

    [Fact]
    public async Task SaveAsync_NormalizesPersistsAndRaisesChangedEvent()
    {
        var service = new JsonApplicationSettingsService(_settingsPath);
        BurrowSettings? changedSettings = null;
        service.SettingsChanged += (_, settings) => changedSettings = settings;

        var saved = await service.SaveAsync(new BurrowSettings
        {
            SamplingIntervalSeconds = 1,
            HistoryRetentionDays = 1000,
            HttpServerEnabled = false,
            HttpServerPort = 10,
            TrayIconEnabled = false,
            McpDestructiveActionsEnabled = true
        });

        Assert.Equal(5, saved.SamplingIntervalSeconds);
        Assert.Equal(365, saved.HistoryRetentionDays);
        Assert.Equal(1024, saved.HttpServerPort);
        Assert.False(saved.HttpServerEnabled);
        Assert.False(saved.TrayIconEnabled);
        Assert.True(saved.McpDestructiveActionsEnabled);
        Assert.NotNull(changedSettings);

        var reloaded = new JsonApplicationSettingsService(_settingsPath);
        Assert.Equal(saved.SamplingIntervalSeconds, reloaded.Current.SamplingIntervalSeconds);
        Assert.Equal(saved.HistoryRetentionDays, reloaded.Current.HistoryRetentionDays);
        Assert.Equal(saved.HttpServerPort, reloaded.Current.HttpServerPort);
        Assert.False(reloaded.Current.HttpServerEnabled);
    }

    public void Dispose()
    {
        if (Directory.Exists(_tempRoot))
        {
            Directory.Delete(_tempRoot, recursive: true);
        }
    }
}
