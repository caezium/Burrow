using BurrowWin.Models;

namespace BurrowWin.Services;

public sealed record FileSystemEntryInfo(
    bool Exists,
    DeletionItemType? ItemType,
    FileAttributes Attributes,
    long? SizeBytes,
    DateTimeOffset? LastWriteTimeUtc)
{
    public bool IsReparsePoint => Exists && Attributes.HasFlag(FileAttributes.ReparsePoint);

    public static FileSystemEntryInfo Missing { get; } = new(false, null, 0, null, null);
}

public interface IWindowsFileSystemInspector
{
    FileSystemEntryInfo Inspect(string path);

    bool TryMeasureSize(string path, CancellationToken cancellationToken, out long sizeBytes);
}
