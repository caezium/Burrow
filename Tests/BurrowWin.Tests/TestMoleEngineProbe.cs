using BurrowWin.Services;

namespace BurrowWin.Tests;

internal sealed class TestMoleEngineProbe : IMoleEngineProbe
{
    private readonly IReadOnlyList<string> _candidatePaths;
    private readonly Dictionary<string, string?> _pathResults;
    private readonly string _powerShellHost;

    public TestMoleEngineProbe(
        IEnumerable<string>? candidatePaths = null,
        IReadOnlyDictionary<string, string?>? pathResults = null,
        string? powerShellHost = null)
    {
        _candidatePaths = candidatePaths?.ToArray() ?? [];
        _pathResults = pathResults?.ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.OrdinalIgnoreCase)
            ?? new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase);
        _powerShellHost = powerShellHost ?? "powershell.exe";
    }

    public IEnumerable<string> GetCandidatePaths()
    {
        return _candidatePaths;
    }

    public string? FindOnPath(string command)
    {
        return _pathResults.TryGetValue(command, out var result) ? result : null;
    }

    public string ResolvePowerShellHost()
    {
        return _powerShellHost;
    }
}
