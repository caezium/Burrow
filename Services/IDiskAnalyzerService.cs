using BurrowWin.Models;

namespace BurrowWin.Services;

public interface IDiskAnalyzerService
{
    Task<DiskUsageNode> AnalyzeAsync(
        string rootPath,
        DiskAnalysisOptions options,
        CancellationToken cancellationToken = default);
}
