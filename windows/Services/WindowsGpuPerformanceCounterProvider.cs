using System.ComponentModel;
using System.Diagnostics;
using System.Security;
using BurrowWin.Models;

namespace BurrowWin.Services;

public sealed class WindowsGpuPerformanceCounterProvider : IGpuTelemetryProvider
{
    private const string CategoryName = "GPU Engine";
    private const string CounterName = "Utilization Percentage";

    public GpuTelemetrySample Capture()
    {
        try
        {
            if (!PerformanceCounterCategory.Exists(CategoryName))
            {
                return GpuTelemetrySample.Unavailable("The GPU Engine performance-counter category is unavailable.");
            }

            var category = new PerformanceCounterCategory(CategoryName);
            var instanceNames = category.GetInstanceNames()
                .Where(name => name.Contains("engtype_3D", StringComparison.OrdinalIgnoreCase))
                .ToArray();

            if (instanceNames.Length == 0)
            {
                return GpuTelemetrySample.Unavailable("No 3D GPU performance-counter instances are available.");
            }

            double total = 0;
            var successfulReads = 0;
            foreach (var instanceName in instanceNames)
            {
                try
                {
                    using var counter = new PerformanceCounter(CategoryName, CounterName, instanceName, readOnly: true);
                    total += counter.NextValue();
                    successfulReads++;
                }
                catch (Exception ex) when (IsExpectedCounterFailure(ex))
                {
                    // GPU engine instances can disappear while the category is enumerated.
                }
            }

            return successfulReads == 0
                ? GpuTelemetrySample.Unavailable("GPU performance-counter instances could not be read.")
                : GpuTelemetrySample.Available(total);
        }
        catch (Exception ex) when (IsExpectedCounterFailure(ex))
        {
            return GpuTelemetrySample.Unavailable($"GPU performance counters are inaccessible ({ex.GetType().Name}).");
        }
    }

    private static bool IsExpectedCounterFailure(Exception exception)
    {
        return exception is Win32Exception or
            InvalidOperationException or
            UnauthorizedAccessException or
            PlatformNotSupportedException or
            SecurityException;
    }
}
