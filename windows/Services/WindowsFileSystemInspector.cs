using BurrowWin.Models;

namespace BurrowWin.Services;

public sealed class WindowsFileSystemInspector : IWindowsFileSystemInspector
{
    public FileSystemEntryInfo Inspect(string path)
    {
        try
        {
            var attributes = File.GetAttributes(path);
            var itemType = attributes.HasFlag(FileAttributes.Directory)
                ? DeletionItemType.Directory
                : DeletionItemType.File;
            long? sizeBytes = itemType == DeletionItemType.File ? new FileInfo(path).Length : null;
            var lastWrite = itemType == DeletionItemType.File
                ? File.GetLastWriteTimeUtc(path)
                : Directory.GetLastWriteTimeUtc(path);
            return new FileSystemEntryInfo(
                true,
                itemType,
                attributes,
                sizeBytes,
                new DateTimeOffset(lastWrite, TimeSpan.Zero));
        }
        catch (Exception ex) when (ex is FileNotFoundException or DirectoryNotFoundException)
        {
            return FileSystemEntryInfo.Missing;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Security.SecurityException or ArgumentException or NotSupportedException)
        {
            // Fail closed: an uninspectable component is treated like a reparse hazard.
            return new FileSystemEntryInfo(true, null, FileAttributes.ReparsePoint, null, null);
        }
    }

    public bool TryMeasureSize(string path, CancellationToken cancellationToken, out long sizeBytes)
    {
        sizeBytes = 0;
        try
        {
            var entry = Inspect(path);
            if (!entry.Exists)
            {
                return true;
            }

            if (entry.IsReparsePoint)
            {
                return false;
            }

            if (entry.ItemType == DeletionItemType.File)
            {
                sizeBytes = entry.SizeBytes ?? 0;
                return true;
            }

            var pending = new Stack<string>();
            pending.Push(path);
            while (pending.Count > 0)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var directory = pending.Pop();
                foreach (var child in Directory.EnumerateFileSystemEntries(directory))
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    var childEntry = Inspect(child);
                    if (!childEntry.Exists || childEntry.IsReparsePoint)
                    {
                        return false;
                    }

                    if (childEntry.ItemType == DeletionItemType.Directory)
                    {
                        pending.Push(child);
                    }
                    else
                    {
                        checked
                        {
                            sizeBytes += childEntry.SizeBytes ?? 0;
                        }
                    }
                }
            }

            return true;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Security.SecurityException or OverflowException or ArgumentException or NotSupportedException)
        {
            sizeBytes = 0;
            return false;
        }
    }
}
