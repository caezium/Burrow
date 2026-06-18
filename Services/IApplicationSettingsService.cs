using BurrowWin.Models;

namespace BurrowWin.Services;

public interface IApplicationSettingsService
{
    string SettingsFilePath { get; }

    BurrowSettings Current { get; }

    event EventHandler<BurrowSettings>? SettingsChanged;

    Task<BurrowSettings> SaveAsync(BurrowSettings settings, CancellationToken cancellationToken = default);

    BurrowSettings Reload();
}
