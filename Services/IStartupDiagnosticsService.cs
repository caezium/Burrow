namespace BurrowWin.Services;

public interface IStartupDiagnosticsService
{
    string LogPath { get; }

    void Record(string phase, string message);

    void RecordException(string phase, Exception exception);
}
