namespace BurrowWin.ViewModels;

public sealed class DashboardBarSample
{
    public DashboardBarSample(double height)
    {
        Height = Math.Clamp(height, 6, 58);
    }

    public double Height { get; }
}
