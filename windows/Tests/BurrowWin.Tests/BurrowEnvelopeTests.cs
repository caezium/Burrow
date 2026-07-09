using BurrowWin.Models;
using Xunit;

namespace BurrowWin.Tests;

// Binds the Windows GUI to burrow-cli's unified result envelope (caezium/burrow-cli#4):
// one shape per call, branch on `ok`. Mirrors the burrow-cli-side tests.
// NOTE: authored without a local .NET/Windows toolchain — verified on CI only.
public sealed class BurrowEnvelopeTests
{
    [Fact]
    public void Parses_Success_And_Branches_On_Ok()
    {
        var e = BurrowEnvelope.Parse(
            """{"ok":true,"burrow_cli":"0.0.1","engine":"burrow-engine","command":"status","data":{"health_score":92}}""");

        Assert.True(e.Ok);
        Assert.Equal("status", e.Command);
        Assert.Equal(92, e.Data.GetProperty("health_score").GetInt32());
        Assert.Null(e.Error);
    }

    [Fact]
    public void Parses_Failure_With_Error_And_No_Data()
    {
        var e = BurrowEnvelope.Parse(
            """{"ok":false,"burrow_cli":"0.0.1","engine":"burrow-engine","command":"uninstall","error":"needs an app"}""");

        Assert.False(e.Ok);
        Assert.Equal("uninstall", e.Command);
        Assert.Equal("needs an app", e.Error);
    }
}
