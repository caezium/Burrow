using System.Diagnostics;
using System.Text;
using System.Text.Json;
using BurrowWin.Models;

namespace BurrowWin.Services;

/// <summary>
/// Runs the bundled <c>burrow.exe</c> conductor and parses its stable envelope. Mirrors the macOS
/// BurrowConductor: the conductor wraps the engine with the unified <c>{ok, data|error}</c>
/// contract, so the app parses ONE shape for every command. Resolves <c>burrow.exe</c> beside the
/// app (Assets\burrow.exe), points it at the bundled engine via <c>BURROW_ENGINE_DIR</c>
/// (Assets\Mole, where burrow-engine.cmd forwards to mole.ps1), and — when the conductor isn't
/// bundled or fails — the caller falls back to the direct engine (<see cref="MoleEngineService"/>).
/// </summary>
public sealed class BurrowConductorService
{
    private static IEnumerable<string> BaseDirectories()
    {
        var processPath = Environment.ProcessPath;
        if (!string.IsNullOrWhiteSpace(processPath))
        {
            var directory = Path.GetDirectoryName(processPath);
            if (!string.IsNullOrWhiteSpace(directory))
            {
                yield return directory;
            }
        }

        yield return AppContext.BaseDirectory;
    }

    /// <summary>Candidate locations for the bundled conductor, beside the app under Assets\.</summary>
    internal static IReadOnlyList<string> CandidateExecutablePaths(IEnumerable<string> baseDirectories)
    {
        return baseDirectories
            .Where(directory => !string.IsNullOrWhiteSpace(directory))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Select(directory => Path.Combine(directory, "Assets", "burrow.exe"))
            .ToArray();
    }

    /// <summary>The bundled conductor path, or null if this build didn't ship one.</summary>
    public static string? ResolveExecutable()
    {
        return CandidateExecutablePaths(BaseDirectories()).FirstOrDefault(File.Exists);
    }

    /// <summary>The bundled engine dir handed to the conductor via BURROW_ENGINE_DIR, or null.</summary>
    public static string? ResolveEngineDir()
    {
        return BaseDirectories()
            .Select(directory => Path.Combine(directory, "Assets", "Mole"))
            .FirstOrDefault(Directory.Exists);
    }

    /// <summary>True when a bundled conductor is present; callers branch on this to fall back.</summary>
    public bool IsAvailable => ResolveExecutable() is not null;

    /// <summary>The argv for a JSON one-shot: <c>&lt;command&gt; [args…] --json</c>.</summary>
    internal static IReadOnlyList<string> BuildArguments(string command, IReadOnlyList<string> arguments)
    {
        var list = new List<string>(arguments.Count + 2) { command };
        list.AddRange(arguments);
        list.Add("--json");
        return list;
    }

    /// <summary>
    /// The conductor args for a destructive maintenance action, from MCP's <c>confirm</c> flag.
    /// <c>burrow</c> defaults to dry-run, so a CONFIRMED (live) run needs <c>--apply</c>; an
    /// unconfirmed run passes nothing (dry-run preview). The mo→burrow inversion, spelled once
    /// + unit-tested so the destructive mapping can't silently drift.
    /// </summary>
    internal static IReadOnlyList<string> ActionArguments(bool confirm)
        => confirm ? new[] { "--apply" } : Array.Empty<string>();

    /// <summary>
    /// Run <c>burrow &lt;command&gt; [args…] --json</c> and return the parsed success envelope.
    /// Throws <see cref="InvalidOperationException"/> when no conductor is bundled, and
    /// <see cref="BurrowConductorException"/> on a timeout/cancel, empty or garbled output, or an
    /// <c>ok:false</c> envelope (carrying the classified error kind so the UI can react).
    /// </summary>
    public async Task<BurrowEnvelope> CaptureAsync(
        string command,
        IReadOnlyList<string> arguments,
        CancellationToken cancellationToken = default)
    {
        var executable = ResolveExecutable()
            ?? throw new InvalidOperationException("the bundled burrow conductor is not available");

        var startInfo = new ProcessStartInfo
        {
            FileName = executable,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var argument in BuildArguments(command, arguments))
        {
            startInfo.ArgumentList.Add(argument);
        }

        startInfo.Environment["NO_COLOR"] = "1";
        var engineDir = ResolveEngineDir();
        if (engineDir is not null)
        {
            startInfo.Environment["BURROW_ENGINE_DIR"] = engineDir;
        }

        // Drain stdout/stderr via events (like MoleEngineService) so a full pipe buffer can't
        // deadlock the wait.
        var stdout = new StringBuilder();
        var syncRoot = new object();
        using var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        process.OutputDataReceived += (_, e) =>
        {
            if (e.Data is not null)
            {
                lock (syncRoot)
                {
                    stdout.AppendLine(e.Data);
                }
            }
        };
        process.ErrorDataReceived += (_, _) => { /* human line on stderr; the envelope is on stdout */ };

        if (!process.Start())
        {
            throw new BurrowConductorException("process_failed", $"burrow {command} could not be started");
        }

        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        try
        {
            await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            TryKill(process);
            throw new BurrowConductorException("process_failed", $"burrow {command} was cancelled");
        }

        string output;
        lock (syncRoot)
        {
            output = stdout.ToString().Trim();
        }

        if (output.Length == 0)
        {
            throw new BurrowConductorException(
                "process_failed", $"burrow {command} produced no output (exit {process.ExitCode})");
        }

        BurrowEnvelope envelope;
        try
        {
            envelope = BurrowEnvelope.Parse(output);
        }
        catch (JsonException ex)
        {
            throw new BurrowConductorException("error", $"burrow {command} output was not a valid envelope: {ex.Message}");
        }

        if (!envelope.Ok)
        {
            throw new BurrowConductorException(
                envelope.Error?.Kind ?? "error",
                envelope.Error?.Message ?? $"burrow {command} failed");
        }

        return envelope;
    }

    private static void TryKill(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch
        {
            // Best effort.
        }
    }
}

/// <summary>A conductor failure carrying the envelope's classified error kind
/// (permission_denied / unsupported / not_found / process_failed / error).</summary>
public sealed class BurrowConductorException : Exception
{
    public string Kind { get; }

    public BurrowConductorException(string kind, string message) : base(message)
    {
        Kind = kind;
    }
}
