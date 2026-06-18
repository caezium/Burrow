namespace BurrowWin.Models;

public sealed record DiskAnalysisOptions(int MaxDepth = 2, int MaxChildrenPerNode = 12)
{
    public int SafeMaxDepth => Math.Clamp(MaxDepth, 0, 8);

    public int SafeMaxChildrenPerNode => Math.Clamp(MaxChildrenPerNode, 1, 100);
}
