using BurrowWin.Models;
using BurrowWin.Services;
using Xunit;

namespace BurrowWin.Tests;

public sealed class DiskTreemapLayoutTests
{
    [Fact]
    public void Build_UsesLargestChildrenAndFillsAvailableArea()
    {
        var root = new DiskUsageNode(
            "root",
            "C:\\root",
            300,
            100,
            [
                new DiskUsageNode("Large", "C:\\root\\Large", 200, 66),
                new DiskUsageNode("Small", "C:\\root\\Small", 100, 33)
            ]);

        var tiles = DiskTreemapLayout.Build(root, 600, 300);

        Assert.Equal(2, tiles.Count);
        Assert.Equal("Large", tiles[0].Name);
        Assert.True(tiles[0].Width * tiles[0].Height > tiles[1].Width * tiles[1].Height);
        Assert.All(tiles, tile =>
        {
            Assert.InRange(tile.X, 0, 600);
            Assert.InRange(tile.Y, 0, 300);
            Assert.InRange(tile.Width, 10, 600);
            Assert.InRange(tile.Height, 10, 300);
        });
    }

    [Fact]
    public void Build_ReturnsRootTileWhenRootHasNoChildren()
    {
        var root = new DiskUsageNode("root", "C:\\root", 120, 100);

        var tiles = DiskTreemapLayout.Build(root, 400, 200);

        Assert.Single(tiles);
        Assert.Equal("root", tiles[0].Name);
    }
}
