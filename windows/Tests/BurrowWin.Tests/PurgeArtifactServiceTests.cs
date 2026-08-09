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
        CreateFile(Path.Combine(_root, "LargeProject", "LargeProject.csproj"), 2);
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
        var deletionService = new RecordingSafeDeletionService();
        var service = new PurgeArtifactService(_root, Path.Combine(_root, "missing.txt"), deletionService);
        var projects = await service.PreviewAsync([_root]);

        var authorization = service.ConfirmRemoval(projects);
        var batch = await service.RemoveAsync(projects, authorization);

        var result = Assert.Single(batch.ItemResults);
        Assert.Equal(Models.SafeDeletionStatus.Recycled, result.Status);
        Assert.True(Directory.Exists(Path.Combine(_root, "Project", "node_modules")));
        Assert.True(File.Exists(sourceFile));
        Assert.Single(deletionService.DeletedPaths);
        Assert.Equal(Path.GetFullPath(Path.Combine(_root, "Project", "node_modules")), deletionService.DeletedPaths[0]);
    }

    [Fact]
    public async Task PreviewAsync_RequiresMarkersForGenericArtifactNames()
    {
        CreateFile(Path.Combine(_root, "NodeProject", "package.json"), 2);
        CreateFile(Path.Combine(_root, "NodeProject", "node_modules", "cache.bin"), 10);
        CreateFile(Path.Combine(_root, "NodeProject", "build", "bundle.js"), 20);
        CreateFile(Path.Combine(_root, "DotNetProject", "App.csproj"), 2);
        CreateFile(Path.Combine(_root, "DotNetProject", "obj", "cache.bin"), 30);
        CreateFile(Path.Combine(_root, "CargoProject", "Cargo.toml"), 2);
        CreateFile(Path.Combine(_root, "CargoProject", "target", "cache.bin"), 40);

        var service = new PurgeArtifactService(_root, Path.Combine(_root, "missing.txt"));

        var projects = await service.PreviewAsync([_root]);

        var node = Assert.Single(projects, project => project.Name == "NodeProject");
        Assert.DoesNotContain(node.Artifacts, artifact => artifact.Name == "build");

        var dotnet = Assert.Single(projects, project => project.Name == "DotNetProject");
        Assert.Contains(dotnet.Artifacts, artifact => artifact.Name == "obj");

        var cargo = Assert.Single(projects, project => project.Name == "CargoProject");
        Assert.Contains(cargo.Artifacts, artifact => artifact.Name == "target");
    }

    [Fact]
    public async Task RemoveAsync_RejectsArtifactChangedAfterPreview()
    {
        CreateFile(Path.Combine(_root, "Project", "package.json"), 2);
        var artifactFile = Path.Combine(_root, "Project", "node_modules", "a.bin");
        CreateFile(artifactFile, 10);
        var deletionService = new RecordingSafeDeletionService();
        var service = new PurgeArtifactService(_root, Path.Combine(_root, "missing.txt"), deletionService);
        var projects = await service.PreviewAsync([_root]);
        var authorization = service.ConfirmRemoval(projects);
        await File.AppendAllTextAsync(artifactFile, "changed");

        var batch = await service.RemoveAsync(projects, authorization);

        Assert.Equal(Models.SafeDeletionStatus.Rejected, Assert.Single(batch.ItemResults).Status);
        Assert.Empty(deletionService.DeletedPaths);
    }

    [Fact]
    public async Task RemoveAsync_RejectsWhenProjectMarkerDisappears()
    {
        var marker = Path.Combine(_root, "Project", "package.json");
        CreateFile(marker, 2);
        CreateFile(Path.Combine(_root, "Project", "node_modules", "a.bin"), 10);
        var deletionService = new RecordingSafeDeletionService();
        var service = new PurgeArtifactService(_root, Path.Combine(_root, "missing.txt"), deletionService);
        var projects = await service.PreviewAsync([_root]);
        var authorization = service.ConfirmRemoval(projects);
        File.Delete(marker);

        var batch = await service.RemoveAsync(projects, authorization);

        Assert.Equal(Models.SafeDeletionStatus.Rejected, Assert.Single(batch.ItemResults).Status);
        Assert.Empty(deletionService.DeletedPaths);
    }

    [Fact]
    public async Task RemoveAsync_RejectsEligibleArtifactThatWasNotInCurrentPreview()
    {
        var projectPath = Path.Combine(_root, "Project");
        CreateFile(Path.Combine(projectPath, "package.json"), 2);
        CreateFile(Path.Combine(projectPath, "node_modules", "a.bin"), 10);
        var artifactPath = Path.Combine(projectPath, "node_modules");
        var project = new Models.PurgeProjectCandidate(
            "Project",
            projectPath,
            "package.json",
            [new Models.PurgeArtifactCandidate("node_modules", artifactPath, "Directory", "JavaScript/Node.js", 10)]);
        var deletionService = new RecordingSafeDeletionService();
        var service = new PurgeArtifactService(_root, Path.Combine(_root, "missing.txt"), deletionService);
        var projects = new[] { project };
        var authorization = service.ConfirmRemoval(projects);

        var batch = await service.RemoveAsync(projects, authorization);

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

    private static void CreateFile(string path, int bytes)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllBytes(path, Enumerable.Repeat((byte)1, bytes).ToArray());
    }
}
