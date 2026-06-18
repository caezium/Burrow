using BurrowWin.Models;

namespace BurrowWin.ViewModels;

public sealed class AnalyzeSidebarItemViewModel
{
    public AnalyzeSidebarItemViewModel(DiskUsageNode node)
    {
        Name = node.Name;
        Path = node.Path;
        SizeText = node.SizeText;
    }

    public string Name { get; }

    public string Path { get; }

    public string SizeText { get; }
}
