namespace BurrowWin.Models;

public sealed record MoleCommandResult(
    int ExitCode,
    string StandardOutput,
    string StandardError,
    bool WasCancelled,
    TimeSpan Duration)
{
    public bool Succeeded => ExitCode == 0 && !WasCancelled;

    public string CombinedOutput
    {
        get
        {
            if (string.IsNullOrWhiteSpace(StandardError))
            {
                return StandardOutput;
            }

            if (string.IsNullOrWhiteSpace(StandardOutput))
            {
                return StandardError;
            }

            return $"{StandardOutput.TrimEnd()}{Environment.NewLine}{StandardError.TrimEnd()}";
        }
    }
}
