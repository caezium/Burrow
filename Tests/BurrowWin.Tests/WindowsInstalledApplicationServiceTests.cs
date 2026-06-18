using BurrowWin.Services;
using Xunit;

namespace BurrowWin.Tests;

public sealed class WindowsInstalledApplicationServiceTests
{
    [Fact]
    public void CreateApplicationFromRegistryValues_ReturnsApplication()
    {
        var values = new Dictionary<string, object?>
        {
            ["DisplayName"] = "Example App",
            ["Publisher"] = "Example Publisher",
            ["DisplayVersion"] = "1.2.3",
            ["InstallLocation"] = @"C:\Program Files\Example",
            ["UninstallString"] = "uninstall.exe",
            ["EstimatedSize"] = 1024
        };

        var app = WindowsInstalledApplicationService.CreateApplicationFromRegistryValues("example-key", values, "Registry");

        Assert.NotNull(app);
        Assert.Equal("Example App", app.Name);
        Assert.Equal("Example Publisher", app.Publisher);
        Assert.Equal("1.2.3", app.Version);
        Assert.Equal(1_048_576, app.SizeBytes);
        Assert.Equal("1 MB", app.SizeText);
    }

    [Fact]
    public void CreateApplicationFromRegistryValues_FiltersProtectedOrSystemEntries()
    {
        var protectedValues = new Dictionary<string, object?>
        {
            ["DisplayName"] = "Microsoft Windows Desktop Runtime",
            ["EstimatedSize"] = 100
        };
        var systemValues = new Dictionary<string, object?>
        {
            ["DisplayName"] = "Vendor Helper",
            ["SystemComponent"] = 1
        };

        Assert.Null(WindowsInstalledApplicationService.CreateApplicationFromRegistryValues("protected", protectedValues, "Registry"));
        Assert.Null(WindowsInstalledApplicationService.CreateApplicationFromRegistryValues("system", systemValues, "Registry"));
    }

    [Fact]
    public void BuildLeftoverPaths_ContainsExpectedApplicationDataLocations()
    {
        var app = WindowsInstalledApplicationService.CreateApplicationFromRegistryValues(
            "example-key",
            new Dictionary<string, object?>
            {
                ["DisplayName"] = "Example: App",
                ["Publisher"] = "Example Publisher",
                ["InstallLocation"] = @"C:\Program Files\Example"
            },
            "Registry");

        Assert.NotNull(app);

        var paths = WindowsInstalledApplicationService.BuildLeftoverPaths(app);

        Assert.Contains(paths, path => path.Category == "Install location" && path.Path == @"C:\Program Files\Example");
        Assert.Contains(paths, path => path.Category == "Local app data" && path.Path.Contains("Example App", StringComparison.Ordinal));
        Assert.Contains(paths, path => path.Category == "Publisher roaming data" && path.Path.Contains("Example Publisher", StringComparison.Ordinal));
        Assert.DoesNotContain(paths, path => path.Path.Contains(':', StringComparison.Ordinal) && !path.Path.StartsWith("C:", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void TrySplitCommandLine_ParsesQuotedExecutable()
    {
        var parsed = WindowsInstalledApplicationService.TrySplitCommandLine(
            "\"C:\\Program Files\\Demo\\uninstall.exe\" /remove /prompt",
            out var fileName,
            out var arguments);

        Assert.True(parsed);
        Assert.Equal("C:\\Program Files\\Demo\\uninstall.exe", fileName);
        Assert.Equal("/remove /prompt", arguments);
    }

    [Fact]
    public void IsSafeDeletionTarget_BlocksRoots()
    {
        var root = Path.GetPathRoot(Environment.SystemDirectory)!;

        Assert.False(WindowsInstalledApplicationService.IsSafeDeletionTarget(root));
        Assert.False(WindowsInstalledApplicationService.IsSafeDeletionTarget(Environment.GetFolderPath(Environment.SpecialFolder.Windows)));
    }

    [Fact]
    public async Task RemoveLeftoversAsync_RemovesSafeDirectory()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), "BurrowWinTests", Guid.NewGuid().ToString("N"));
        var target = Path.Combine(tempRoot, "DemoApp");
        Directory.CreateDirectory(target);
        await File.WriteAllTextAsync(Path.Combine(target, "cache.bin"), "data");

        try
        {
            var service = new WindowsInstalledApplicationService();

            var results = await service.RemoveLeftoversAsync([new("Test", target, 4)]);

            var result = Assert.Single(results);
            Assert.True(result.Succeeded, result.Message);
            Assert.False(Directory.Exists(target));
        }
        finally
        {
            if (Directory.Exists(tempRoot))
            {
                Directory.Delete(tempRoot, recursive: true);
            }
        }
    }
}
