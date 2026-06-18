using CommunityToolkit.Mvvm.ComponentModel;

namespace BurrowWin.Models;

public partial class CleanupPreviewItem : ObservableObject
{
    public CleanupPreviewItem(string category, string path, string sizeText, long sizeBytes, int? itemCount)
    {
        Category = category;
        Path = path;
        SizeText = sizeText;
        SizeBytes = sizeBytes;
        ItemCount = itemCount;
    }

    public string Category { get; }

    public string Path { get; }

    public string SizeText { get; }

    public long SizeBytes { get; }

    public int? ItemCount { get; }

    [ObservableProperty]
    private bool isSelected = true;
}
