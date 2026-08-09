namespace BurrowWin.Services;

public sealed record PathSafetyResult(
    bool IsSafe,
    string ReasonCode,
    string Message,
    string? CanonicalPath,
    string? CanonicalScopeRoot,
    FileSystemEntryInfo? TargetInfo)
{
    public static PathSafetyResult Reject(string code, string message, string? canonicalPath = null, string? canonicalScopeRoot = null) =>
        new(false, code, message, canonicalPath, canonicalScopeRoot, null);
}

public interface IWindowsPathSafetyPolicy
{
    PathSafetyResult Validate(string path, string approvedScopeRoot);

    PathSafetyResult ValidateScopeRoot(string scopeRoot);
}
