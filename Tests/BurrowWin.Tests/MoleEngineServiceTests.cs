using BurrowWin.Models;
using BurrowWin.Services;
using Xunit;

namespace BurrowWin.Tests;

public sealed class MoleEngineServiceTests : IDisposable
{
    private readonly string _tempRoot = Path.Combine(Path.GetTempPath(), "BurrowWinTests", Guid.NewGuid().ToString("N"));

    public MoleEngineServiceTests()
    {
        Directory.CreateDirectory(_tempRoot);
    }

    [Fact]
    public void GetAvailability_ReturnsMissing_WhenNoCandidateOrPathEntryExists()
    {
        var service = new MoleEngineService(new TestMoleEngineProbe());

        var availability = service.GetAvailability();

        Assert.False(availability.IsAvailable);
        Assert.Equal(MoleEngineKind.Missing, availability.Kind);
        Assert.Contains("Mole engine was not found", availability.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void GetAvailability_PrefersBundledCandidate_BeforePathLookup()
    {
        var script = CreatePowerShellEngineScript();
        var pathEngine = Path.Combine(_tempRoot, "path-mo.cmd");
        File.WriteAllText(pathEngine, "@echo off\r\necho path\r\n");
        var probe = new TestMoleEngineProbe(
            candidatePaths: [script],
            pathResults: new Dictionary<string, string?> { ["mo"] = pathEngine });
        var service = new MoleEngineService(probe);

        var availability = service.GetAvailability();

        Assert.True(availability.IsAvailable);
        Assert.Equal(script, availability.Path);
        Assert.Equal(MoleEngineKind.PowerShellScript, availability.Kind);
    }

    [Fact]
    public async Task ExecuteCommandAsync_RunsPowerShellEngine_AndStreamsOutput()
    {
        var script = CreatePowerShellEngineScript();
        var probe = new TestMoleEngineProbe(candidatePaths: [script], powerShellHost: "powershell.exe");
        var service = new MoleEngineService(probe);
        var streamed = new List<string>();

        var result = await service.ExecuteCommandAsync("clean --dry-run \"C:\\Program Files\\Demo\"", streamed.Add);

        Assert.True(result.Succeeded, result.CombinedOutput);
        Assert.Contains("command=clean", result.StandardOutput, StringComparison.Ordinal);
        Assert.Contains("args=--dry-run|C:\\Program Files\\Demo", result.StandardOutput, StringComparison.Ordinal);
        Assert.Contains("command=clean", streamed);
    }

    [Fact]
    public async Task ExecuteCommandAsync_CapturesNonZeroExitCode()
    {
        var script = CreatePowerShellEngineScript();
        var service = new MoleEngineService(new TestMoleEngineProbe(candidatePaths: [script]));

        var result = await service.ExecuteCommandAsync("fail");

        Assert.False(result.Succeeded);
        Assert.Equal(9, result.ExitCode);
        Assert.Contains("failure from fake engine", result.StandardError, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ExecuteCommandAsync_RunsCommandScript_AndPreservesQuotedArguments()
    {
        var scriptPath = Path.Combine(_tempRoot, "mo.cmd");
        await File.WriteAllTextAsync(
            scriptPath,
            """
            @echo off
            echo command=%~1
            echo first=%~2
            echo second=%~3
            exit /b 0
            """);
        var service = new MoleEngineService(new TestMoleEngineProbe(candidatePaths: [scriptPath]));

        var result = await service.ExecuteCommandAsync(@"clean --dry-run ""C:\Program Files\Demo""");

        Assert.True(result.Succeeded, result.CombinedOutput);
        Assert.Contains("command=clean", result.StandardOutput, StringComparison.Ordinal);
        Assert.Contains("first=--dry-run", result.StandardOutput, StringComparison.Ordinal);
        Assert.Contains("second=C:\\Program Files\\Demo", result.StandardOutput, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ExecuteCommandAsync_RecordsAnsiFreeHistorySummary()
    {
        var script = CreateAnsiPowerShellEngineScript();
        var historyPath = Path.Combine(_tempRoot, "history.jsonl");
        var history = new JsonOperationHistoryService(historyPath);
        var service = new MoleEngineService(
            new TestMoleEngineProbe(candidatePaths: [script], powerShellHost: "powershell.exe"),
            history);

        var result = await service.ExecuteCommandAsync("clean --dry-run");
        var entries = await history.ReadRecentAsync(1);

        Assert.True(result.Succeeded, result.CombinedOutput);
        var entry = Assert.Single(entries);
        Assert.Equal("clean", entry.Operation);
        Assert.Equal("clean --dry-run", entry.Arguments);
        Assert.DoesNotContain("\u001B", entry.Summary, StringComparison.Ordinal);
        Assert.DoesNotContain("[1;35m", entry.Summary, StringComparison.Ordinal);
        Assert.DoesNotContain("? Clean", entry.Summary, StringComparison.Ordinal);
        Assert.Contains("Clean Your Windows", entry.Summary, StringComparison.Ordinal);
        Assert.Contains("Dry Run Mode - Preview only", entry.Summary, StringComparison.Ordinal);
    }

    public void Dispose()
    {
        if (Directory.Exists(_tempRoot))
        {
            Directory.Delete(_tempRoot, recursive: true);
        }
    }

    private string CreatePowerShellEngineScript()
    {
        var scriptPath = Path.Combine(_tempRoot, "mole.ps1");
        File.WriteAllText(
            scriptPath,
            """
            param(
                [Parameter(Position = 0)]
                [string]$Command,
                [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
                [string[]]$CommandArgs
            )

            Write-Output "command=$Command"
            Write-Output "args=$($CommandArgs -join '|')"

            if ($Command -eq 'fail') {
                [Console]::Error.WriteLine("failure from fake engine")
                exit 9
            }

            exit 0
            """);
        return scriptPath;
    }

    private string CreateAnsiPowerShellEngineScript()
    {
        var scriptPath = Path.Combine(_tempRoot, "ansi-mole.ps1");
        File.WriteAllText(
            scriptPath,
            """
            param(
                [Parameter(Position = 0)]
                [string]$Command,
                [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
                [string[]]$CommandArgs
            )

            $esc = [char]27
            Write-Output "$esc[1;35mClean Your Windows$esc[0m"
            Write-Output ""
            Write-Output "  $esc[33mDry Run Mode$esc[0m - Preview only"
            Write-Output "? Clean task"
            Write-Output ([string]([char]26))
            exit 0
            """);
        return scriptPath;
    }
}
