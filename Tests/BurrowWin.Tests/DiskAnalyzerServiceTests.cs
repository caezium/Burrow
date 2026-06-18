using BurrowWin.Models;
using BurrowWin.Services;
using Xunit;

namespace BurrowWin.Tests;

public sealed class DiskAnalyzerServiceTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "BurrowWinDiskTests", Guid.NewGuid().ToString("N"));

    public DiskAnalyzerServiceTests()
    {
        Directory.CreateDirectory(_root);
    }

    [Fact]
    public async Task AnalyzeAsync_ReturnsTotalSizeAndLargestChildrenFirst()
    {
        CreateFile(Path.Combine(_root, "root.bin"), 10);
        CreateFile(Path.Combine(_root, "Large", "a.bin"), 200);
        CreateFile(Path.Combine(_root, "Small", "b.bin"), 50);

        var service = new DiskAnalyzerService();

        var node = await service.AnalyzeAsync(_root, new DiskAnalysisOptions(MaxDepth: 1, MaxChildrenPerNode: 10));

        Assert.Equal(260, node.SizeBytes);
        Assert.Equal(2, node.Children.Count);
        Assert.Equal("Large", node.Children[0].Name);
        Assert.Equal(200, node.Children[0].SizeBytes);
        Assert.Equal("Small", node.Children[1].Name);
        Assert.Equal(50, node.Children[1].SizeBytes);
    }

    [Fact]
    public async Task AnalyzeAsync_RespectsChildLimit()
    {
        CreateFile(Path.Combine(_root, "A", "a.bin"), 10);
        CreateFile(Path.Combine(_root, "B", "b.bin"), 30);
        CreateFile(Path.Combine(_root, "C", "c.bin"), 20);

        var service = new DiskAnalyzerService();

        var node = await service.AnalyzeAsync(_root, new DiskAnalysisOptions(MaxDepth: 1, MaxChildrenPerNode: 2));

        Assert.Equal(2, node.Children.Count);
        Assert.Equal("B", node.Children[0].Name);
        Assert.Equal("C", node.Children[1].Name);
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
