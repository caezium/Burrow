using System;
using System.IO;
using System.Linq;
using BurrowWin.Services;
using Xunit;

namespace BurrowWin.Tests;

// Pins BurrowConductorService's pure command shaping + resolution. The spawn itself can't run in
// CI (no bundled burrow.exe), so these cover everything up to it; the envelope parse is covered by
// BurrowEnvelopeTests. Mirrors the macOS BurrowEnvelopeTests so both GUIs prove the same contract.
public class BurrowConductorServiceTests
{
    [Fact]
    public void BuildArguments_AppendsJsonAfterPositionalArgs()
    {
        Assert.Equal(
            new[] { "analyze", @"C:\Users", "--json" },
            BurrowConductorService.BuildArguments("analyze", new[] { @"C:\Users" }));
    }

    [Fact]
    public void BuildArguments_NoArgs_IsJustCommandPlusJson()
    {
        Assert.Equal(
            new[] { "status", "--json" },
            BurrowConductorService.BuildArguments("status", Array.Empty<string>()));
    }

    [Fact]
    public void CandidateExecutablePaths_LookBesideTheApp_UnderAssets()
    {
        var paths = BurrowConductorService
            .CandidateExecutablePaths(new[] { @"C:\App", @"C:\App" })
            .ToList();

        Assert.Single(paths); // duplicate base dir deduped (case-insensitive)
        Assert.EndsWith(Path.Combine("Assets", "burrow.exe"), paths[0]);
    }

    [Fact]
    public void CandidateExecutablePaths_SkipsBlankBaseDirs()
    {
        var paths = BurrowConductorService
            .CandidateExecutablePaths(new[] { "", "   ", @"C:\App" })
            .ToList();

        Assert.Single(paths);
    }

    // Safety-critical: the destructive confirm→apply mapping (burrow defaults to dry-run).
    [Fact]
    public void ActionArguments_Confirmed_AddsApply()
    {
        // A confirmed (live) maintenance run MUST add --apply, or a "real" clean silently no-ops.
        Assert.Equal(new[] { "--apply" }, BurrowConductorService.ActionArguments(confirm: true));
    }

    [Fact]
    public void ActionArguments_Unconfirmed_IsPreviewOnly()
    {
        // Unconfirmed → no --apply → burrow's default dry-run (preview). Must NOT delete for real.
        Assert.Empty(BurrowConductorService.ActionArguments(confirm: false));
    }
}
