using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using BurrowWin.Models;
using BurrowWin.Services;

namespace BurrowWin.ViewModels;

public sealed class DiskTreemapTileViewModel
{
    private static readonly string[] Palette =
    [
        "#5B8FBD",
        "#5FA894",
        "#B99243",
        "#7467B6",
        "#A85A70",
        "#9C6747",
        "#5B7FAF",
        "#5E8A61"
    ];

    public DiskTreemapTileViewModel(DiskTreemapRect rect)
    {
        Name = rect.Name;
        Path = rect.Path;
        SizeText = SystemTelemetryFormatter.Bytes(rect.SizeBytes);
        X = rect.X;
        Y = rect.Y;
        Width = rect.Width;
        Height = rect.Height;
        FontSize = rect.Width > 220 && rect.Height > 150 ? 20 : 14;
        ShowDetail = rect.Width > 118 && rect.Height > 72;
        LabelOpacity = ShowDetail ? 1 : 0;
        IconVisibility = rect.Width > 150 && rect.Height > 96 ? Visibility.Visible : Visibility.Collapsed;
        FillBrush = new SolidColorBrush(ParseColor(Palette[rect.ColorIndex % Palette.Length]));
    }

    public string Name { get; }

    public string Path { get; }

    public string SizeText { get; }

    public double X { get; }

    public double Y { get; }

    public double Width { get; }

    public double Height { get; }

    public double FontSize { get; }

    public bool ShowDetail { get; }

    public double LabelOpacity { get; }

    public Visibility IconVisibility { get; }

    public SolidColorBrush FillBrush { get; }

    private static Windows.UI.Color ParseColor(string hex)
    {
        var value = Convert.ToUInt32(hex.TrimStart('#'), 16);
        return Windows.UI.Color.FromArgb(
            255,
            (byte)((value >> 16) & 0xFF),
            (byte)((value >> 8) & 0xFF),
            (byte)(value & 0xFF));
    }
}
