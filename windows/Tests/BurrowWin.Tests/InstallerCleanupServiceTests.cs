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
        var deletionService = new RecordingSafeDeletionService();
        var service = new InstallerCleanupService(_root, 30, deletionService);
        var candidate = (await service.PreviewAsync()).Single();

        var candidates = new[] { candidate };
        var authorization = service.ConfirmRemoval(candidates);
        var batch = await service.RemoveAsync(candidates, authorization);

        var result = Assert.Single(batch.ItemResults);
        Assert.Equal(Models.SafeDeletionStatus.Recycled, result.Status);
        Assert.True(File.Exists(file));
        Assert.Single(deletionService.DeletedPaths);
        Assert.Equal(Path.GetFullPath(file), deletionService.DeletedPaths[0]);
    }

    [Fact]
    public async Task RemoveAsync_RejectsCandidateOutsideDownloadsRoot()
    {
        var outside = Path.Combine(Path.GetTempPath(), $"burrowwin-outside-{Guid.NewGuid():N}.msi");
        await File.WriteAllTextAsync(outside, "outside");

        try
        {
            var deletionService = new RecordingSafeDeletionService();
            var service = new InstallerCleanupService(_root, 30, deletionService);
            var candidate = new Models.InstallerCleanupCandidate(
                "outside.msi",
                outside,
                "MSI installer",
                7,
                DateTimeOffset.UtcNow.AddDays(-90));

            var candidates = new[] { candidate };
            var authorization = service.ConfirmRemoval(candidates);
            var batch = await service.RemoveAsync(candidates, authorization);

            var result = Assert.Single(batch.ItemResults);
            Assert.Equal(Models.SafeDeletionStatus.Rejected, result.Status);
            Assert.True(File.Exists(outside));
            Assert.Empty(deletionService.DeletedPaths);
        }
        finally
        {
            File.Delete(outside);
        }
    }

    [Fact]
    public async Task RemoveAsync_RejectsCandidateChangedBetweenPreviewAndApply()
    {
        var file = CreateFile("changed.zip", 1024, DateTime.UtcNow.AddDays(-90));
        var deletionService = new RecordingSafeDeletionService();
        var service = new InstallerCleanupService(_root, 30, deletionService);
        var candidates = (await service.PreviewAsync()).ToArray();
        var authorization = service.ConfirmRemoval(candidates);
        await File.AppendAllTextAsync(file, "changed");

        var batch = await service.RemoveAsync(candidates, authorization);

        Assert.Equal(Models.SafeDeletionStatus.Rejected, Assert.Single(batch.ItemResults).Status);
        Assert.Empty(deletionService.DeletedPaths);
    }

    [Fact]
    public async Task RemoveAsync_RejectsWhenConfirmationDoesNotMatchSelectedSet()
    {
        _ = CreateFile("one.msi", 1024, DateTime.UtcNow.AddDays(-90));
        _ = CreateFile("two.zip", 2048, DateTime.UtcNow.AddDays(-90));
        var deletionService = new RecordingSafeDeletionService();
        var service = new InstallerCleanupService(_root, 30, deletionService);
        var candidates = (await service.PreviewAsync()).ToArray();
        var authorization = service.ConfirmRemoval([candidates[0]]);

        var batch = await service.RemoveAsync(candidates, authorization);

        Assert.All(batch.ItemResults, result => Assert.Equal(Models.SafeDeletionStatus.Rejected, result.Status));
        Assert.Empty(deletionService.DeletedPaths);
    }

    [Fact]
    public async Task RemoveAsync_RejectsEligibleCandidateThatWasNotInCurrentPreview()
    {
        var file = CreateFile("unpreviewed.msi", 1024, DateTime.UtcNow.AddDays(-90));
        var deletionService = new RecordingSafeDeletionService();
        var service = new InstallerCleanupService(_root, 30, deletionService);
        var info = new FileInfo(file);
        var candidates = new[]
        {
            new Models.InstallerCleanupCandidate(
                info.Name,
                info.FullName,
                "MSI installer",
                info.Length,
                new DateTimeOffset(info.LastWriteTimeUtc, TimeSpan.Zero))
        };
        var authorization = service.ConfirmRemoval(candidates);

        var batch = await service.RemoveAsync(candidates, authorization);

        Assert.Equal(Models.SafeDeletionStatus.Rejected, Assert.Single(batch.ItemResults).Status);
        Assert.Empty(deletionService.DeletedPaths);
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
