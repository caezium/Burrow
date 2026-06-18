using BurrowWin.Services;
using Xunit;

namespace BurrowWin.Tests;

public sealed class InstallerCleanupServiceTests : IDisposable
{
    private readonly string _root;

    public InstallerCleanupServiceTests()
    {
        _root = Path.Combine(Path.GetTempPath(), "BurrowWinInstallerTests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_root);
    }

    [Fact]
    public async Task PreviewAsync_ReturnsOnlyOldTopLevelInstallersAndArchives()
    {
        var oldInstaller = CreateFile("setup.msi", 4096, DateTime.UtcNow.AddDays(-45));
        var oldArchive = CreateFile("sdk.tar.gz", 2048, DateTime.UtcNow.AddDays(-31));
        _ = CreateFile("notes.txt", 1024, DateTime.UtcNow.AddDays(-60));
        _ = CreateFile("fresh.exe", 1024, DateTime.UtcNow.AddDays(-2));

        var nested = Path.Combine(_root, "nested");
        Directory.CreateDirectory(nested);
        File.WriteAllText(Path.Combine(nested, "nested.msi"), "nested");
        File.SetLastWriteTimeUtc(Path.Combine(nested, "nested.msi"), DateTime.UtcNow.AddDays(-60));

        var service = new InstallerCleanupService(_root, daysOld: 30);

        var items = await service.PreviewAsync();

        Assert.Equal(2, items.Count);
        Assert.Contains(items, item => item.Path == oldInstaller && item.Kind == "MSI installer");
        Assert.Contains(items, item => item.Path == oldArchive && item.Kind == "Archive");
        Assert.DoesNotContain(items, item => item.Name == "fresh.exe");
        Assert.DoesNotContain(items, item => item.Name == "nested.msi");
    }

    [Fact]
    public async Task RemoveAsync_RemovesPreviewedInstallerFile()
    {
        var file = CreateFile("driver.iso", 1024, DateTime.UtcNow.AddDays(-90));
        var service = new InstallerCleanupService(_root, daysOld: 30);
        var candidate = (await service.PreviewAsync()).Single();

        var results = await service.RemoveAsync([candidate]);

        var result = Assert.Single(results);
        Assert.True(result.Succeeded);
        Assert.False(File.Exists(file));
    }

    [Fact]
    public async Task RemoveAsync_RejectsCandidateOutsideDownloadsRoot()
    {
        var outside = Path.Combine(Path.GetTempPath(), $"burrowwin-outside-{Guid.NewGuid():N}.msi");
        await File.WriteAllTextAsync(outside, "outside");

        try
        {
            var service = new InstallerCleanupService(_root, daysOld: 30);
            var candidate = new Models.InstallerCleanupCandidate(
                "outside.msi",
                outside,
                "MSI installer",
                7,
                DateTimeOffset.UtcNow.AddDays(-90));

            var results = await service.RemoveAsync([candidate]);

            var result = Assert.Single(results);
            Assert.False(result.Succeeded);
            Assert.True(File.Exists(outside));
        }
        finally
        {
            File.Delete(outside);
        }
    }

    public void Dispose()
    {
        if (Directory.Exists(_root))
        {
            Directory.Delete(_root, recursive: true);
        }
    }

    private string CreateFile(string name, int bytes, DateTime lastWriteUtc)
    {
        var path = Path.Combine(_root, name);
        File.WriteAllBytes(path, Enumerable.Repeat((byte)42, bytes).ToArray());
        File.SetLastWriteTimeUtc(path, lastWriteUtc);
        return path;
    }
}
