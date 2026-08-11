using System.ComponentModel;
using BurrowWin.Models;
using BurrowWin.Services;
using Xunit;

namespace BurrowWin.Tests;

public sealed class GpuTelemetryBackoffProviderTests
{
    [Fact]
    public void Capture_DisabledCounterService_BacksOffAndKeepsZeroDistinctFromUnavailable()
    {
        var now = DateTimeOffset.Parse("2026-08-05T00:00:00Z");
        var source = new ScriptedGpuTelemetryProvider(
            [
                () => throw new Win32Exception(1058, "The service cannot be started because it is disabled."),
                () => GpuTelemetrySample.Available(0)
            ]);
        var provider = new GpuTelemetryBackoffProvider(
            source,
            () => now,
            TimeSpan.FromSeconds(30),
            TimeSpan.FromMinutes(5));

        var unavailable = provider.Capture();

        Assert.False(unavailable.IsAvailable);
        Assert.Null(unavailable.UsagePercent);
        Assert.Equal(now.AddSeconds(30), unavailable.RetryAfter);
        Assert.Contains(nameof(Win32Exception), unavailable.UnavailableReason);
        Assert.Equal(1, source.CaptureCount);

        now = now.AddSeconds(29);
        var cached = provider.Capture();

        Assert.False(cached.IsAvailable);
        Assert.Equal(1, source.CaptureCount);

        now = now.AddSeconds(1);
        var zero = provider.Capture();

        Assert.True(zero.IsAvailable);
        Assert.Equal(0, zero.UsagePercent);
        Assert.Equal("3D 0.0%", zero.Status);
        Assert.Null(zero.RetryAfter);
        Assert.Equal(2, source.CaptureCount);
    }

    [Fact]
    public void Capture_RepeatedUnavailableSamples_UsesBoundedExponentialBackoff()
    {
        var now = DateTimeOffset.Parse("2026-08-05T00:00:00Z");
        var source = new ConstantGpuTelemetryProvider(
            GpuTelemetrySample.Unavailable("Counters unavailable."));
        var provider = new GpuTelemetryBackoffProvider(
            source,
            () => now,
            TimeSpan.FromSeconds(10),
            TimeSpan.FromSeconds(40));

        Assert.Equal(now.AddSeconds(10), provider.Capture().RetryAfter);
        now = now.AddSeconds(10);
        Assert.Equal(now.AddSeconds(20), provider.Capture().RetryAfter);
        now = now.AddSeconds(20);
        Assert.Equal(now.AddSeconds(40), provider.Capture().RetryAfter);
        now = now.AddSeconds(40);
        Assert.Equal(now.AddSeconds(40), provider.Capture().RetryAfter);

        Assert.Equal(4, source.CaptureCount);
    }

    [Fact]
    public void Snapshot_EffectiveGpuUsage_PreservesLegacyZeroAndUnavailableValues()
    {
        var zero = CreateSnapshot("3D 0.0%");
        var nonZero = CreateSnapshot("3D 37.5%");
        var unavailable = CreateSnapshot("Unavailable");

        Assert.True(zero.IsGpuAvailable);
        Assert.Equal(0, zero.EffectiveGpuUsagePercent);
        Assert.True(nonZero.IsGpuAvailable);
        Assert.Equal(37.5, nonZero.EffectiveGpuUsagePercent);
        Assert.False(unavailable.IsGpuAvailable);
        Assert.Null(unavailable.EffectiveGpuUsagePercent);
    }

    private static SystemTelemetrySnapshot CreateSnapshot(string gpuStatus)
    {
        return new SystemTelemetrySnapshot(
            DateTimeOffset.Parse("2026-08-05T00:00:00Z"),
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            gpuStatus,
            []);
    }

    private sealed class ScriptedGpuTelemetryProvider : IGpuTelemetryProvider
    {
        private readonly Queue<Func<GpuTelemetrySample>> _captures;

        public ScriptedGpuTelemetryProvider(IEnumerable<Func<GpuTelemetrySample>> captures)
        {
            _captures = new Queue<Func<GpuTelemetrySample>>(captures);
        }

        public int CaptureCount { get; private set; }

        public GpuTelemetrySample Capture()
        {
            CaptureCount++;
            return _captures.Dequeue()();
        }
    }

    private sealed class ConstantGpuTelemetryProvider : IGpuTelemetryProvider
    {
        private readonly GpuTelemetrySample _sample;

        public ConstantGpuTelemetryProvider(GpuTelemetrySample sample)
        {
            _sample = sample;
        }

        public int CaptureCount { get; private set; }

        public GpuTelemetrySample Capture()
        {
            CaptureCount++;
            return _sample;
        }
    }
}
