using BurrowWin.Services;
using Xunit;

namespace BurrowWin.Tests;

public sealed class LocalStartupDiagnosticsServiceTests : IDisposable
{
    private readonly string _tempRoot = Path.Combine(Path.GetTempPath(), "BurrowWinTests", Guid.NewGuid().ToString("N"));

    [Fact]
    public void FormatLine_NormalizesSingleLineOutput()
    {
        var timestamp = new DateTimeOffset(2026, 6, 15, 12, 30, 0, TimeSpan.Zero);

        var line = LocalStartupDiagnosticsService.FormatLine(timestamp, "launch\r\nphase", "started\r\nnow");

        Assert.Equal("2026-06-15T12:30:00.0000000+00:00 [launch  phase] started  now", line);
    }

    [Fact]
    public void Record_WritesToConfiguredLogPath()
    {
        var path = Path.Combine(_tempRoot, "startup.log");
        var diagnostics = new LocalStartupDiagnosticsService(path);

        diagnostics.Record("window", "activated");

        var text = File.ReadAllText(path);
        Assert.Contains("[window] activated", text);
    }

    public void Dispose()
    {
        if (Directory.Exists(_tempRoot))
        {
            Directory.Delete(_tempRoot, recursive: true);
        }
    }
}
