using BurrowWin.Models;

namespace BurrowWin.Services;

public static class CleanPreviewParser
{
    public static string PreviewFilePath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config", "mole", "clean-list.txt");

    public static IReadOnlyList<CleanupPreviewItem> LoadLive()
    {
        if (!File.Exists(PreviewFilePath))
        {
            return Array.Empty<CleanupPreviewItem>();
        }

        return Parse(File.ReadAllText(PreviewFilePath));
    }

    public static IReadOnlyList<CleanupPreviewItem> Parse(string text)
    {
        var items = new List<CleanupPreviewItem>();
        var category = "Cleanup";

        foreach (var rawLine in text.Split('\n'))
        {
            var line = rawLine.Trim();
            if (string.IsNullOrWhiteSpace(line))
            {
                continue;
            }

            if (line.StartsWith("===", StringComparison.Ordinal) && line.EndsWith("===", StringComparison.Ordinal))
            {
                category = line.Trim('=').Trim();
                continue;
            }

            if (line.StartsWith('#'))
            {
                continue;
            }

            var markerIndex = line.IndexOf(" #", StringComparison.Ordinal);
            if (markerIndex < 0)
            {
                continue;
            }

            var path = line[..markerIndex].Trim();
            var metadata = line[(markerIndex + 2)..].Trim();
            var parts = metadata.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
            if (path.Length == 0 || parts.Length == 0)
            {
                continue;
            }

            var sizeText = parts[0];
            var itemCount = TryParseItemCount(parts.Skip(1).FirstOrDefault());
            items.Add(new CleanupPreviewItem(category, path, sizeText, ParseSize(sizeText), itemCount));
        }

        return items;
    }

    private static int? TryParseItemCount(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return null;
        }

        var number = new string(text.TakeWhile(char.IsDigit).ToArray());
        return int.TryParse(number, out var value) ? value : null;
    }

    private static long ParseSize(string text)
    {
        var normalized = text.Trim().ToUpperInvariant();
        var units = new (string Suffix, double Multiplier)[]
        {
            ("TB", 1_099_511_627_776d),
            ("GB", 1_073_741_824d),
            ("MB", 1_048_576d),
            ("KB", 1024d),
            ("B", 1d)
        };

        foreach (var (suffix, multiplier) in units)
        {
            if (!normalized.EndsWith(suffix, StringComparison.Ordinal))
            {
                continue;
            }

            var number = normalized[..^suffix.Length].Trim();
            return double.TryParse(number, out var value) ? (long)(value * multiplier) : 0;
        }

        return 0;
    }
}
