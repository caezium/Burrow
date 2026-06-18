using Microsoft.UI.Xaml.Media;

namespace BurrowWin.ViewModels;

public sealed class HistoryChartSeries
{
    public HistoryChartSeries(string latestText, string averageText, PointCollection points)
    {
        LatestText = latestText;
        AverageText = averageText;
        Points = points;
    }

    public string LatestText { get; }

    public string AverageText { get; }

    public PointCollection Points { get; }

    public static HistoryChartSeries Empty(string latestText, string averageText)
    {
        return new HistoryChartSeries(latestText, averageText, []);
    }
}
