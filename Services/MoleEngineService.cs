using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;
using BurrowWin.Models;

namespace BurrowWin.Services;

public sealed class MoleEngineService : IMoleEngineService
{
    private static readonly Regex AnsiEscapePattern = new(@"\x1B\[[0-?]*[ -/]*[@-~]", RegexOptions.Compiled);

    private readonly IMoleEngineProbe _engineProbe;
    private readonly IOperationHistoryService? _operationHistoryService;

    public MoleEngineService(IMoleEngineProbe engineProbe, IOperationHistoryService? operationHistoryService = null)
    {
        _engineProbe = engineProbe;
        _operationHistoryService = operationHistoryService;
    }

    public MoleEngineAvailability GetAvailability()
    {
        return ResolveEngine();
    }

    public Task<MoleCommandResult> ExecuteCommandAsync(
        string arguments,
        Action<string>? onProgress = null,
        CancellationToken cancellationToken = default)
    {
        return ExecuteAsync(SplitArguments(arguments), onProgress, cancellationToken);
    }

    public async Task<MoleCommandResult> ExecuteAsync(
        IReadOnlyList<string> arguments,
        Action<string>? onProgress = null,
        CancellationToken cancellationToken = default)
    {
        var engine = ResolveEngine();
        if (!engine.IsAvailable || engine.Path is null)
        {
            var missingResult = new MoleCommandResult(127, string.Empty, engine.Message, false, TimeSpan.Zero);
            await RecordHistoryAsync(arguments, missingResult, "mole").ConfigureAwait(false);
            return missingResult;
        }

        var startInfo = BuildStartInfo(engine, arguments);
        var stdout = new StringBuilder();
        var stderr = new StringBuilder();
        var startedAt = Stopwatch.GetTimestamp();

        using var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        object syncRoot = new();

        process.OutputDataReceived += (_, e) =>
        {
            if (e.Data is null)
            {
                return;
            }

            lock (syncRoot)
            {
                stdout.AppendLine(e.Data);
            }

            onProgress?.Invoke(e.Data);
        };

        process.ErrorDataReceived += (_, e) =>
        {
            if (e.Data is null)
            {
                return;
            }

            lock (syncRoot)
            {
                stderr.AppendLine(e.Data);
            }

            onProgress?.Invoke(e.Data);
        };

        try
        {
            if (!process.Start())
            {
                var failedStart = new MoleCommandResult(
                    127,
                    string.Empty,
                    "Mole process could not be started.",
                    false,
                    TimeSpan.Zero);
                await RecordHistoryAsync(arguments, failedStart, "mole").ConfigureAwait(false);
                return failedStart;
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
                var cancelledResult = BuildResult(process, stdout, stderr, true, startedAt);
                await RecordHistoryAsync(arguments, cancelledResult, "mole").ConfigureAwait(false);
                return cancelledResult;
            }

            var result = BuildResult(process, stdout, stderr, false, startedAt);
            await RecordHistoryAsync(arguments, result, "mole").ConfigureAwait(false);
            return result;
        }
        catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception or IOException)
        {
            var exceptionResult = new MoleCommandResult(
                127,
                string.Empty,
                ex.Message,
                false,
                Stopwatch.GetElapsedTime(startedAt));
            await RecordHistoryAsync(arguments, exceptionResult, "mole").ConfigureAwait(false);
            return exceptionResult;
        }
    }

    private async Task RecordHistoryAsync(IReadOnlyList<string> arguments, MoleCommandResult result, string source)
    {
        if (_operationHistoryService is null)
        {
            return;
        }

        var operation = arguments.Count > 0 ? arguments[0] : "version";
        var entry = new OperationHistoryEntry(
            DateTimeOffset.UtcNow,
            source,
            operation,
            string.Join(" ", arguments),
            result.ExitCode,
            result.Succeeded,
            (long)result.Duration.TotalMilliseconds,
            BuildHistorySummary(result));

        try
        {
            await _operationHistoryService.RecordAsync(entry).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }
    }

    private static string BuildHistorySummary(MoleCommandResult result)
    {
        var output = string.IsNullOrWhiteSpace(result.StandardError)
            ? result.StandardOutput
            : result.StandardError;
        output = NormalizeHistoryText(output);
        if (output.Length == 0)
        {
            return result.Succeeded ? "Command completed" : "Command failed without output";
        }

        return output.Length <= 240 ? output : output[..240];
    }

    private static string NormalizeHistoryText(string value)
    {
        var withoutAnsi = AnsiEscapePattern.Replace(value, string.Empty);
        var builder = new StringBuilder(withoutAnsi.Length);
        foreach (var ch in withoutAnsi)
        {
            if (!char.IsControl(ch) || ch is '\r' or '\n' or '\t')
            {
                builder.Append(ch);
            }
        }

        var lines = builder
            .ToString()
            .Replace("\r\n", "\n", StringComparison.Ordinal)
            .Replace('\r', '\n')
            .Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Where(line => line.Length > 0)
            .Select(NormalizeHistoryLine)
            .Where(line => line.Length > 0);

        return string.Join(" | ", lines).Trim();
    }

    private static string NormalizeHistoryLine(string line)
    {
        var withoutIconPlaceholders = Regex.Replace(line, "(^|\\s)[?\\uFFFD](?=\\s)", "$1");
        return Regex.Replace(withoutIconPlaceholders, @"\s+", " ").Trim();
    }

    private static MoleCommandResult BuildResult(
        Process process,
        StringBuilder stdout,
        StringBuilder stderr,
        bool wasCancelled,
        long startedAt)
    {
        var exitCode = wasCancelled ? -1 : process.ExitCode;
        return new MoleCommandResult(
            exitCode,
            stdout.ToString(),
            stderr.ToString(),
            wasCancelled,
            Stopwatch.GetElapsedTime(startedAt));
    }

    private ProcessStartInfo BuildStartInfo(MoleEngineAvailability engine, IReadOnlyList<string> arguments)
    {
        var startInfo = new ProcessStartInfo
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            WorkingDirectory = Path.GetDirectoryName(engine.Path!) ?? AppContext.BaseDirectory,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };

        startInfo.Environment["NO_COLOR"] = "1";

        switch (engine.Kind)
        {
            case MoleEngineKind.PowerShellScript:
                startInfo.FileName = _engineProbe.ResolvePowerShellHost();
                startInfo.ArgumentList.Add("-NoProfile");
                startInfo.ArgumentList.Add("-ExecutionPolicy");
                startInfo.ArgumentList.Add("Bypass");
                startInfo.ArgumentList.Add("-File");
                startInfo.ArgumentList.Add(engine.Path!);
                foreach (var argument in arguments)
                {
                    startInfo.ArgumentList.Add(argument);
                }

                break;

            case MoleEngineKind.CommandScript:
                startInfo.FileName = _engineProbe.ResolvePowerShellHost();
                startInfo.ArgumentList.Add("-NoProfile");
                startInfo.ArgumentList.Add("-ExecutionPolicy");
                startInfo.ArgumentList.Add("Bypass");
                startInfo.ArgumentList.Add("-Command");
                startInfo.ArgumentList.Add(BuildPowerShellInvocation(engine.Path!, arguments));
                break;

            default:
                startInfo.FileName = engine.Path!;
                foreach (var argument in arguments)
                {
                    startInfo.ArgumentList.Add(argument);
                }

                break;
        }

        return startInfo;
    }

    private MoleEngineAvailability ResolveEngine()
    {
        foreach (var candidate in _engineProbe.GetCandidatePaths())
        {
            if (File.Exists(candidate))
            {
                return Available(candidate);
            }
        }

        var fromPath = _engineProbe.FindOnPath("mo") ?? _engineProbe.FindOnPath("mo.cmd") ?? _engineProbe.FindOnPath("mole.ps1");
        if (fromPath is not null)
        {
            return Available(fromPath);
        }

        return new MoleEngineAvailability(
            false,
            null,
            MoleEngineKind.Missing,
            "Mole engine was not found. Add Assets\\mo.exe, Assets\\Mole\\mole.ps1, or install Mole so `mo` is on PATH.");
    }

    private static MoleEngineAvailability Available(string path)
    {
        var kind = GetKind(path);
        return new MoleEngineAvailability(true, path, kind, $"Mole engine resolved at {path}");
    }

    private static MoleEngineKind GetKind(string path)
    {
        var extension = Path.GetExtension(path).ToLowerInvariant();
        return extension switch
        {
            ".ps1" => MoleEngineKind.PowerShellScript,
            ".cmd" or ".bat" => MoleEngineKind.CommandScript,
            _ => MoleEngineKind.Executable
        };
    }

    private static string BuildPowerShellInvocation(string executable, IReadOnlyList<string> arguments)
    {
        return string.Join(" ", new[] { "&", QuoteForPowerShell(executable) }.Concat(arguments.Select(QuoteForPowerShell)));
    }

    private static string QuoteForPowerShell(string value)
    {
        return $"'{value.Replace("'", "''")}'";
    }

    private static IReadOnlyList<string> SplitArguments(string arguments)
    {
        var result = new List<string>();
        var current = new StringBuilder();
        var inQuotes = false;

        for (var index = 0; index < arguments.Length; index++)
        {
            var ch = arguments[index];
            if (ch == '"')
            {
                inQuotes = !inQuotes;
                continue;
            }

            if (char.IsWhiteSpace(ch) && !inQuotes)
            {
                Flush();
                continue;
            }

            current.Append(ch);
        }

        Flush();
        return result;

        void Flush()
        {
            if (current.Length == 0)
            {
                return;
            }

            result.Add(current.ToString());
            current.Clear();
        }
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
            // Best effort cancellation.
        }
    }
}
