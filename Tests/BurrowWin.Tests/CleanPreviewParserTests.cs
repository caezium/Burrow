using BurrowWin.Services;
using Xunit;

namespace BurrowWin.Tests;

public sealed class CleanPreviewParserTests
{
    [Fact]
    public void Parse_ReturnsCategorizedItems_WithSizesAndCounts()
    {
        const string preview = """
            # Mole Cleanup Preview

            === Browser Caches ===
            C:\Users\me\AppData\Local\Cache  # 1.5GB, 12 items
            C:\Users\me\AppData\Local\Other  # 512KB

            === Developer Tools ===
            C:\Users\me\.npm  # 25MB, 4 items

            # Potential cleanup: 1.53GB
            # Items: 16
            """;

        var items = CleanPreviewParser.Parse(preview);

        Assert.Equal(3, items.Count);
        Assert.Equal("Browser Caches", items[0].Category);
        Assert.Equal(@"C:\Users\me\AppData\Local\Cache", items[0].Path);
        Assert.Equal("1.5GB", items[0].SizeText);
        Assert.Equal(1_610_612_736, items[0].SizeBytes);
        Assert.Equal(12, items[0].ItemCount);
        Assert.Equal("Developer Tools", items[2].Category);
        Assert.Equal(26_214_400, items[2].SizeBytes);
    }

    [Fact]
    public void Parse_IgnoresSummaryAndMalformedLines()
    {
        const string preview = """
            malformed
            # Items: 2
            === Empty ===
            === Valid ===
            C:\Temp\file.tmp  # 42KB
            """;

        var items = CleanPreviewParser.Parse(preview);

        var item = Assert.Single(items);
        Assert.Equal("Valid", item.Category);
        Assert.Equal(43_008, item.SizeBytes);
    }
}
