using BurrowWin.Models;
using BurrowWin.Services;
using Xunit;

namespace BurrowWin.Tests;

public sealed class WindowsInstalledApplicationServiceTests
{
    [Fact]
    public void LeftoverCandidate_DefaultsToNotSelected()
    {
        var candidate = new LeftoverCandidate("Local app data", @"C:\Users\me\AppData\Local\Example", 1);

        Assert.False(candidate.IsSelected);
    }

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
        Assert.False(WindowsInstalledApplicationService.IsSafeDeletionTarget(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.Windows),
            "System32")));
        Assert.False(WindowsInstalledApplicationService.IsSafeDeletionTarget(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            "Demo")));
    }

    [Fact]
    public void IsSafeLeftoverCandidate_AllowsOnlyGeneratedAppDataTargets()
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

        Assert.True(WindowsInstalledApplicationService.IsSafeLeftoverCandidate(
            new("Local app data", Path.Combine(localAppData, "ExampleApp"), 1)));
        Assert.False(WindowsInstalledApplicationService.IsSafeLeftoverCandidate(
            new("Local app data", Path.Combine(localAppData, "Microsoft", "Windows"), 1)));
        Assert.False(WindowsInstalledApplicationService.IsSafeLeftoverCandidate(
            new("Install location", Path.Combine(profile, "Downloads", "ExampleApp"), 1)));
        Assert.False(WindowsInstalledApplicationService.IsSafeLeftoverCandidate(
            new("Program data", Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "ExampleApp"), 1)));
    }

    [Fact]
    public async Task RemoveLeftoversAsync_RoutesSafeDirectoryThroughDeletionService()
    {
        var appName = $"BurrowWinTest{Guid.NewGuid():N}";
        var target = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            appName);
        Directory.CreateDirectory(target);
        await File.WriteAllTextAsync(Path.Combine(target, "cache.bin"), "data");

        try
        {
            var deletionService = new RecordingSafeDeletionService();
            var service = new WindowsInstalledApplicationService(deletionService);
            var app = new InstalledApplication(
                appName,
                appName,
                null,
                null,
                null,
                null,
                "Test",
                0);
            var preview = await service.PreviewLeftoversAsync(app);
            var candidate = Assert.Single(preview, item => item.Path == target);
            candidate.IsSelected = true;
            var candidates = new[] { candidate };
            var authorization = service.ConfirmLeftoverRemoval(candidates);

            var batch = await service.RemoveLeftoversAsync(candidates, authorization);

            var result = Assert.Single(batch.ItemResults);
            Assert.Equal(SafeDeletionStatus.Recycled, result.Status);
            Assert.Single(deletionService.DeletedPaths);
            Assert.Equal(Path.GetFullPath(target), deletionService.DeletedPaths[0]);
        }
        finally
        {
            if (Directory.Exists(target))
            {
                Directory.Delete(target, recursive: true);
            }
        }
    }

    [Fact]
    public async Task RemoveLeftoversAsync_RejectsCandidateThatWasNotDiscoveredByPreview()
    {
        var target = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            $"BurrowUnapproved{Guid.NewGuid():N}");
        Directory.CreateDirectory(target);
        await File.WriteAllTextAsync(Path.Combine(target, "cache.bin"), "data");

        try
        {
            var deletionService = new RecordingSafeDeletionService();
            var service = new WindowsInstalledApplicationService(deletionService);
            var candidate = new LeftoverCandidate(
                "Local app data",
                target,
                4,
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData));
            var candidates = new[] { candidate };
            var authorization = service.ConfirmLeftoverRemoval(candidates);

            var batch = await service.RemoveLeftoversAsync(candidates, authorization);

            Assert.Equal(SafeDeletionStatus.Rejected, Assert.Single(batch.ItemResults).Status);
            Assert.Empty(deletionService.DeletedPaths);
        }
        finally
        {
            Directory.Delete(target, recursive: true);
        }
    }
}
