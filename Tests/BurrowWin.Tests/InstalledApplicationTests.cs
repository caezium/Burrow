using BurrowWin.Models;
using Xunit;

namespace BurrowWin.Tests;

public sealed class InstalledApplicationTests
{
    [Fact]
    public void DetailLine_UsesAsciiSeparators()
    {
        var app = new InstalledApplication(
            "id",
            "Example",
            "Publisher",
            "1.0",
            @"C:\Apps\Example",
            "uninstall.exe",
            "Registry",
            1024);

        Assert.Equal(@"1 KB - Registry - C:\Apps\Example", app.DetailLine);
    }
}
