namespace BurrowWin.Models;

public enum MoleEngineKind
{
    Missing,
    Executable,
    CommandScript,
    PowerShellScript
}

public sealed record MoleEngineAvailability(
    bool IsAvailable,
    string? Path,
    MoleEngineKind Kind,
    string Message);
