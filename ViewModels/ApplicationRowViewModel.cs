using CommunityToolkit.Mvvm.ComponentModel;
using Microsoft.UI.Xaml;
using BurrowWin.Models;

namespace BurrowWin.ViewModels;

public partial class ApplicationRowViewModel : ObservableObject
{
    public ApplicationRowViewModel(InstalledApplication application)
    {
        Application = application;
    }

    public InstalledApplication Application { get; }

    public string Id => Application.Id;

    public string Name => Application.Name;

    public string VersionText => string.IsNullOrWhiteSpace(Application.Version) ? "version unknown" : $"v{Application.Version}";

    public string Source => Application.Source;

    public string InstallLocation => string.IsNullOrWhiteSpace(Application.InstallLocation)
        ? "No install path"
        : Application.InstallLocation;

    public string Initials => Application.Initials;

    public string SizeText => Application.SizeText;

    public string DetailLine => $"{VersionText} - {Source} - {InstallLocation}";

    public string RightSummary => Application.SizeText;

    public string ChevronText => IsExpanded ? "v" : ">";

    public Visibility DetailVisibility => IsExpanded ? Visibility.Visible : Visibility.Collapsed;

    [ObservableProperty]
    private bool isExpanded;

    partial void OnIsExpandedChanged(bool value)
    {
        OnPropertyChanged(nameof(ChevronText));
        OnPropertyChanged(nameof(DetailVisibility));
    }
}
