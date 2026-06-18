using BurrowWin.Services;
using Xunit;

namespace BurrowWin.Tests;

public sealed class PurgeArtifactServiceTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "BurrowWinPurgeTests", Guid.NewGuid().ToString("N"));

    public PurgeArtifactServiceTests()
    {
        Directory.CreateDirectory(_root);
    }

    [Fact]
    public async Task PreviewAsync_ReturnsProjectsWithArtifactsLargestFirst()
    {
        CreateFile(Path.Combine(_root, "SmallProject", "package.json"), 2);
        CreateFile(Path.Combine(_root, "SmallProject", "node_modules", "a.bin"), 10);
        CreateFile(Path.Combine(_root, "LargeProject", "go.mod"), 2);
        CreateFile(Path.Combine(_root, "LargeProject", "bin", "app.dll"), 90);
        CreateFile(Path.Combine(_root, "LargeProject", "build.log"), 12);
        CreateFile(Path.Combine(_root, "NoArtifacts", "package.json"), 2);

        var service = new PurgeArtifactService(_root, Path.Combine(_root, "missing.txt"));

        var projects = await service.PreviewAsync([_root]);

        Assert.Equal(2, projects.Count);
        Assert.Equal("LargeProject", projects[0].Name);
        Assert.Equal(102, projects[0].TotalSizeBytes);
        Assert.Equal(2, projects[0].ArtifactCount);
        Assert.Equal("SmallProject", projects[1].Name);
        Assert.Contains(projects[0].Artifacts, artifact => artifact.Name == "bin");
        Assert.Contains(projects[0].Artifacts, artifact => artifact.Name == "build.log");
    }

    [Fact]
    public async Task RemoveAsync_RemovesOnlyPreviewArtifacts()
    {
        var sourceFile = Path.Combine(_root, "Project", "package.json");
        var artifactFile = Path.Combine(_root, "Project", "node_modules", "a.bin");
        CreateFile(sourceFile, 2);
        CreateFile(artifactFile, 10);
        var service = new PurgeArtifactService(_root, Path.Combine(_root, "missing.txt"));
        var projects = await service.PreviewAsync([_root]);

        var results = await service.RemoveAsync(projects);

        Assert.Single(results);
        Assert.True(results[0].Succeeded);
        Assert.False(Directory.Exists(Path.Combine(_root, "Project", "node_modules")));
        Assert.True(File.Exists(sourceFile));
    }

    public void Dispose()
    {
        if (Directory.Exists(_root))
        {
            Directory.Delete(_root, recursive: true);
        }
    }

    private static void CreateFile(string path, int bytes)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllBytes(path, Enumerable.Repeat((byte)1, bytes).ToArray());
    }
}
