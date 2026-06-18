using System.Diagnostics;
using System.Net.Sockets;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using BurrowWin.Models;

namespace BurrowWin.Services;

public sealed class WindowsSystemTelemetryService : ISystemTelemetryService
{
    private static readonly TimeSpan SampleWindow = TimeSpan.FromMilliseconds(350);

    public async Task<SystemTelemetrySnapshot> CaptureAsync(CancellationToken cancellationToken = default)
    {
        var cpuBefore = GetTotalProcessorTime();
        var networkBefore = GetNetworkBytes();
        var processesBefore = GetProcessSamples();
        var startedAt = Stopwatch.GetTimestamp();

        await Task.Delay(SampleWindow, cancellationToken).ConfigureAwait(false);

        var elapsed = Stopwatch.GetElapsedTime(startedAt);
        var cpuAfter = GetTotalProcessorTime();
        var networkAfter = GetNetworkBytes();
        var processesAfter = GetProcessSamples();
        var memory = GetMemory();
        var disk = GetSystemDisk();
        var battery = GetBattery();

        var cpuPercent = elapsed.TotalMilliseconds <= 0
            ? 0
            : (cpuAfter - cpuBefore).TotalMilliseconds / (elapsed.TotalMilliseconds * Environment.ProcessorCount) * 100;

        var networkSeconds = Math.Max(elapsed.TotalSeconds, 0.001);

        return new SystemTelemetrySnapshot(
            DateTimeOffset.Now,
            ClampPercent(cpuPercent),
            Percent(memory.UsedBytes, memory.TotalBytes),
            memory.UsedBytes,
            memory.TotalBytes,
            Percent(disk.UsedBytes, disk.TotalBytes),
            disk.UsedBytes,
            disk.TotalBytes,
            Math.Max(0, (networkAfter.ReceivedBytes - networkBefore.ReceivedBytes) / networkSeconds),
            Math.Max(0, (networkAfter.SentBytes - networkBefore.SentBytes) / networkSeconds),
            GetGpuStatus(),
            BuildTopProcesses(processesBefore, processesAfter, elapsed))
        {
            NetworkInterfaceName = networkAfter.InterfaceName,
            NetworkIPv4Address = networkAfter.IPv4Address,
            HasBattery = battery.HasBattery,
            BatteryChargePercent = battery.ChargePercent,
            BatteryStatusText = battery.StatusText,
            BatteryHealthText = battery.HealthText,
            BatteryEstimatedSecondsRemaining = battery.EstimatedSecondsRemaining
        };
    }

    private static TimeSpan GetTotalProcessorTime()
    {
        var total = TimeSpan.Zero;
        foreach (var process in Process.GetProcesses())
        {
            try
            {
                total += process.TotalProcessorTime;
            }
            catch
            {
                // Processes can exit or deny access while being sampled.
            }
            finally
            {
                process.Dispose();
            }
        }

        return total;
    }

    private static (long TotalBytes, long UsedBytes) GetMemory()
    {
        var status = new MemoryStatusEx();
        if (!GlobalMemoryStatusEx(status))
        {
            return (0, 0);
        }

        var total = checked((long)status.ullTotalPhys);
        var available = checked((long)status.ullAvailPhys);
        return (total, Math.Max(0, total - available));
    }

    private static (long TotalBytes, long UsedBytes) GetSystemDisk()
    {
        var systemRoot = Path.GetPathRoot(Environment.GetFolderPath(Environment.SpecialFolder.Windows)) ?? "C:\\";
        try
        {
            var drive = new DriveInfo(systemRoot);
            var total = drive.TotalSize;
            return (total, Math.Max(0, total - drive.AvailableFreeSpace));
        }
        catch
        {
            return (0, 0);
        }
    }

    private static BatteryTelemetrySample GetBattery()
    {
        if (!GetSystemPowerStatus(out var status))
        {
            return BatteryTelemetrySample.Unavailable;
        }

        var hasBattery = (status.BatteryFlag & BatteryFlagNoSystemBattery) == 0 &&
            status.BatteryLifePercent <= 100;
        if (!hasBattery)
        {
            return BatteryTelemetrySample.Unavailable;
        }

        var statusText = BuildBatteryStatusText(status);
        var healthText = BuildBatteryHealthText(status);
        int? remainingSeconds = status.BatteryLifeTime >= 0 ? status.BatteryLifeTime : null;

        return new BatteryTelemetrySample(
            true,
            status.BatteryLifePercent,
            statusText,
            healthText,
            remainingSeconds);
    }

    private static string BuildBatteryStatusText(SystemPowerStatus status)
    {
        if ((status.BatteryFlag & BatteryFlagCharging) != 0)
        {
            return "charging";
        }

        return status.ACLineStatus switch
        {
            0 => "discharging",
            1 => "plugged in",
            _ => "unknown"
        };
    }

    private static string BuildBatteryHealthText(SystemPowerStatus status)
    {
        if ((status.BatteryFlag & BatteryFlagCritical) != 0)
        {
            return "Critical";
        }

        if ((status.BatteryFlag & BatteryFlagLow) != 0)
        {
            return "Low";
        }

        return "Good";
    }

    private static NetworkCounterSample GetNetworkBytes()
    {
        long received = 0;
        long sent = 0;
        NetworkEndpointSample? primaryEndpoint = null;

        foreach (var networkInterface in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (networkInterface.OperationalStatus != OperationalStatus.Up ||
                networkInterface.NetworkInterfaceType == NetworkInterfaceType.Loopback)
            {
                continue;
            }

            try
            {
                var stats = networkInterface.GetIPv4Statistics();
                received += stats.BytesReceived;
                sent += stats.BytesSent;
                var score = stats.BytesReceived + stats.BytesSent;
                var endpoint = new NetworkEndpointSample(
                    string.IsNullOrWhiteSpace(networkInterface.Name) ? "network" : networkInterface.Name,
                    GetPrimaryIPv4Address(networkInterface),
                    score);

                if (primaryEndpoint is null ||
                    (endpoint.HasAddress && !primaryEndpoint.HasAddress) ||
                    (endpoint.HasAddress == primaryEndpoint.HasAddress && endpoint.Score > primaryEndpoint.Score))
                {
                    primaryEndpoint = endpoint;
                }
            }
            catch
            {
                // Some virtual adapters do not expose IPv4 statistics consistently.
            }
        }

        return new NetworkCounterSample(
            received,
            sent,
            primaryEndpoint?.Name ?? "network",
            primaryEndpoint?.IPv4Address ?? "unavailable");
    }

    private static string GetPrimaryIPv4Address(NetworkInterface networkInterface)
    {
        try
        {
            return networkInterface
                .GetIPProperties()
                .UnicastAddresses
                .Where(address => address.Address.AddressFamily == AddressFamily.InterNetwork)
                .Select(address => address.Address.ToString())
                .FirstOrDefault(address => !string.IsNullOrWhiteSpace(address)) ?? "unavailable";
        }
        catch
        {
            return "unavailable";
        }
    }

    private static IReadOnlyList<ProcessTelemetry> BuildTopProcesses(
        IReadOnlyDictionary<int, ProcessSample> before,
        IReadOnlyDictionary<int, ProcessSample> after,
        TimeSpan elapsed)
    {
        var elapsedMilliseconds = Math.Max(elapsed.TotalMilliseconds, 1);
        var processCount = Math.Max(Environment.ProcessorCount, 1);
        var processes = after.Values
            .Select(sample =>
            {
                before.TryGetValue(sample.ProcessId, out var previous);
                var delta = previous is null
                    ? TimeSpan.Zero
                    : sample.TotalProcessorTime - previous.TotalProcessorTime;
                var cpuPercent = delta.TotalMilliseconds <= 0
                    ? 0
                    : delta.TotalMilliseconds / (elapsedMilliseconds * processCount) * 100;

                return new ProcessTelemetry(
                    sample.Name,
                    sample.ProcessId,
                    sample.WorkingSetBytes,
                    ClampPercent(cpuPercent),
                    Math.Max(0, sample.TotalProcessorTime.TotalSeconds));
            })
            .ToArray();

        return processes
            .OrderByDescending(process => process.CpuUsagePercent)
            .ThenByDescending(process => process.WorkingSetBytes)
            .Take(8)
            .Concat(processes
                .OrderByDescending(process => process.WorkingSetBytes)
                .ThenByDescending(process => process.CpuUsagePercent)
                .Take(8))
            .GroupBy(process => process.ProcessId)
            .Select(group => group.First())
            .OrderByDescending(process => process.CpuUsagePercent)
            .ThenByDescending(process => process.WorkingSetBytes)
            .Take(12)
            .ToArray();
    }

    private static IReadOnlyDictionary<int, ProcessSample> GetProcessSamples()
    {
        return Process.GetProcesses()
            .Select(TryReadProcessSample)
            .Where(sample => sample is not null)
            .Select(sample => sample!)
            .GroupBy(sample => sample.ProcessId)
            .Select(group => group.First())
            .ToDictionary(sample => sample.ProcessId);
    }

    private static ProcessSample? TryReadProcessSample(Process process)
    {
        try
        {
            return new ProcessSample(
                process.ProcessName,
                process.Id,
                process.WorkingSet64,
                process.TotalProcessorTime);
        }
        catch
        {
            return null;
        }
        finally
        {
            process.Dispose();
        }
    }

    private static IReadOnlyList<ProcessTelemetry> GetTopProcesses()
    {
        return GetProcessSamples()
            .Values
            .Select(sample => new ProcessTelemetry(
                sample.Name,
                sample.ProcessId,
                sample.WorkingSetBytes,
                0,
                Math.Max(0, sample.TotalProcessorTime.TotalSeconds)))
            .OrderByDescending(process => process.WorkingSetBytes)
            .Take(8)
            .ToArray();
    }

    private static string GetGpuStatus()
    {
        try
        {
            const string categoryName = "GPU Engine";
            const string counterName = "Utilization Percentage";

            if (!PerformanceCounterCategory.Exists(categoryName))
            {
                return "Unavailable";
            }

            var category = new PerformanceCounterCategory(categoryName);
            var instanceNames = category.GetInstanceNames()
                .Where(name => name.Contains("engtype_3D", StringComparison.OrdinalIgnoreCase))
                .ToArray();

            if (instanceNames.Length == 0)
            {
                return "Unavailable";
            }

            double total = 0;
            foreach (var instanceName in instanceNames)
            {
                using var counter = new PerformanceCounter(categoryName, counterName, instanceName, readOnly: true);
                try
                {
                    total += counter.NextValue();
                }
                catch
                {
                    // GPU engine instances may disappear while being sampled.
                }
            }

            return $"3D {ClampPercent(total):0.0}%";
        }
        catch (Exception ex) when (ex is InvalidOperationException or UnauthorizedAccessException or PlatformNotSupportedException)
        {
            return "Unavailable";
        }
    }

    private static double Percent(long used, long total)
    {
        return total <= 0 ? 0 : ClampPercent((double)used / total * 100);
    }

    private static double ClampPercent(double value)
    {
        if (double.IsNaN(value) || double.IsInfinity(value))
        {
            return 0;
        }

        return Math.Clamp(value, 0, 100);
    }

    private sealed record ProcessSample(
        string Name,
        int ProcessId,
        long WorkingSetBytes,
        TimeSpan TotalProcessorTime);

    private sealed record NetworkCounterSample(
        long ReceivedBytes,
        long SentBytes,
        string InterfaceName,
        string IPv4Address);

    private sealed record NetworkEndpointSample(
        string Name,
        string IPv4Address,
        long Score)
    {
        public bool HasAddress => !string.Equals(IPv4Address, "unavailable", StringComparison.OrdinalIgnoreCase);
    }

    private sealed record BatteryTelemetrySample(
        bool HasBattery,
        double? ChargePercent,
        string StatusText,
        string HealthText,
        int? EstimatedSecondsRemaining)
    {
        public static BatteryTelemetrySample Unavailable { get; } = new(
            false,
            null,
            "unavailable",
            "Unavailable",
            null);
    }

    private const byte BatteryFlagLow = 2;
    private const byte BatteryFlagCritical = 4;
    private const byte BatteryFlagCharging = 8;
    private const byte BatteryFlagNoSystemBattery = 128;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GlobalMemoryStatusEx([In, Out] MemoryStatusEx lpBuffer);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetSystemPowerStatus(out SystemPowerStatus lpSystemPowerStatus);

    [StructLayout(LayoutKind.Sequential)]
    private struct SystemPowerStatus
    {
        public byte ACLineStatus;
        public byte BatteryFlag;
        public byte BatteryLifePercent;
        public byte SystemStatusFlag;
        public int BatteryLifeTime;
        public int BatteryFullLifeTime;
    }

    [StructLayout(LayoutKind.Sequential)]
    private sealed class MemoryStatusEx
    {
        public uint dwLength;
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;

        public MemoryStatusEx()
        {
            dwLength = (uint)Marshal.SizeOf<MemoryStatusEx>();
        }
    }
}
