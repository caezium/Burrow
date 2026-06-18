namespace BurrowWin.Models;

public sealed record DiskTreemapRect(
    string Name,
    string Path,
    long SizeBytes,
    double X,
    double Y,
    double Width,
    double Height,
    int Depth,
    int ColorIndex);
