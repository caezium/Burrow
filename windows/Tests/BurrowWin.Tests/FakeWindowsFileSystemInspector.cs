using BurrowWin.Models;
using BurrowWin.Services;

namespace BurrowWin.Tests;

internal sealed class FakeWindowsFileSystemInspector : IWindowsFileSystemInspector
{
    private readonly Dictionary<string, FileSystemEntryInfo> _entries = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, long> _measuredSizes = new(StringComparer.OrdinalIgnoreCase);

    public void Set(
        string path,
        DeletionItemType itemType,
        FileAttributes attributes = 0,
        long? sizeBytes = null,
        DateTimeOffset? lastWriteTimeUtc = null,
        long? measuredSizeBytes = null)
    {
        var canonical = Canonical(path);
        if (itemType == DeletionItemType.Directory)
        {
            attributes |= FileAttributes.Directory;
        }

        _entries[canonical] = new FileSystemEntryInfo(
            true,
            itemType,
            attributes,
            sizeBytes,
            lastWriteTimeUtc);
        _measuredSizes[canonical] = measuredSizeBytes ?? sizeBytes ?? 0;
    }

    public void Remove(string path)
    {
        var canonical = Canonical(path);
        _entries.Remove(canonical);
        _measuredSizes.Remove(canonical);
    }

    public FileSystemEntryInfo Inspect(string path)
    {
        return _entries.TryGetValue(Canonical(path), out var entry)
            ? entry
            : FileSystemEntryInfo.Missing;
    }

    public bool TryMeasureSize(string path, CancellationToken cancellationToken, out long sizeBytes)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return _measuredSizes.TryGetValue(Canonical(path), out sizeBytes) || !Inspect(path).Exists;
    }

    private static string Canonical(string path) =>
        Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
}

internal sealed class InlineProgress<T> : IProgress<T>
{
    private readonly Action<T> _handler;

    public InlineProgress(Action<T> handler)
    {
        _handler = handler;
    }

    public void Report(T value) => _handler(value);
}
