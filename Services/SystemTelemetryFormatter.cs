using BurrowWin.Models;

namespace BurrowWin.Services;

public static class SystemTelemetryFormatter
{
    public static string Percent(double value)
    {
        return $"{Math.Clamp(value, 0, 100):0.#}%";
    }

    public static string Bytes(long value)
    {
        var units = new[] { "B", "KB", "MB", "GB", "TB" };
        var index = 0;
        var size = (double)Math.Max(0, value);
        while (size >= 1024 && index < units.Length - 1)
        {
            size /= 1024;
            index++;
        }

        return index == 0 ? $"{size:0} {units[index]}" : $"{size:0.#} {units[index]}";
    }

    public static string Rate(double bytesPerSecond)
    {
        return $"{Bytes((long)Math.Max(0, bytesPerSecond))}/s";
    }

    public static string MemorySummary(SystemTelemetrySnapshot snapshot)
    {
        return $"{Bytes(snapshot.MemoryUsedBytes)} / {Bytes(snapshot.MemoryTotalBytes)}";
    }

    public static string DiskSummary(SystemTelemetrySnapshot snapshot)
    {
        return $"{Bytes(snapshot.DiskUsedBytes)} / {Bytes(snapshot.DiskTotalBytes)}";
    }
}
