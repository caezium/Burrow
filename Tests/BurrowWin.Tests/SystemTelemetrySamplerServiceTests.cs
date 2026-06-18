using BurrowWin.Models;
using BurrowWin.Services;
using Xunit;

namespace BurrowWin.Tests;

public sealed class SystemTelemetrySamplerServiceTests
{
    [Fact]
    public async Task SampleNowAsync_CapturesRecordsAndCachesLatestSnapshot()
    {
        var snapshot = CreateSnapshot(1);
        var telemetry = new ScriptedTelemetryService([snapshot]);
        var history = new RecordingTelemetryHistoryService();
        var sampler = new SystemTelemetrySamplerService(telemetry, history, TimeSpan.FromMinutes(2));

        var sampled = await sampler.SampleNowAsync();

        Assert.Same(snapshot, sampled);
        Assert.Same(snapshot, sampler.LatestSnapshot);
        Assert.Equal(TimeSpan.FromMinutes(2), sampler.SamplingInterval);
        Assert.Equal("windows_native_sampler", sampler.Source);
        Assert.Collection(history.RecordedSnapshots, recorded => Assert.Same(snapshot, recorded));
    }

    [Fact]
    public async Task SampleNowAsync_SerializesConcurrentSampling()
    {
        var first = CreateSnapshot(1);
        var second = CreateSnapshot(2);
        var telemetry = new ScriptedTelemetryService([first, second]);
        var history = new RecordingTelemetryHistoryService();
        var sampler = new SystemTelemetrySamplerService(telemetry, history, TimeSpan.FromSeconds(5));

        await Task.WhenAll(sampler.SampleNowAsync(), sampler.SampleNowAsync());

        Assert.Equal(2, telemetry.CaptureCount);
        Assert.Collection(
            history.RecordedSnapshots,
            recorded => Assert.Same(first, recorded),
            recorded => Assert.Same(second, recorded));
        Assert.Same(second, sampler.LatestSnapshot);
    }

    [Fact]
    public void Constructor_UsesDefaultInterval_ForInvalidInterval()
    {
        var sampler = new SystemTelemetrySamplerService(
            new ScriptedTelemetryService([CreateSnapshot(1)]),
            new RecordingTelemetryHistoryService(),
            TimeSpan.Zero);

        Assert.Equal(SystemTelemetrySamplerService.DefaultSamplingInterval, sampler.SamplingInterval);
    }

    private static SystemTelemetrySnapshot CreateSnapshot(int offset)
    {
        return new SystemTelemetrySnapshot(
            DateTimeOffset.Parse("2026-06-15T00:00:00Z").AddMinutes(offset),
            12.5 + offset,
            45,
            4,
            8,
            70,
            3,
            4,
            100,
            50,
            "GPU pending",
            [new ProcessTelemetry("demo", 123 + offset, 4096)]);
    }

    private sealed class ScriptedTelemetryService : ISystemTelemetryService
    {
        private readonly Queue<SystemTelemetrySnapshot> _snapshots;
        private readonly SemaphoreSlim _lock = new(1, 1);

        public ScriptedTelemetryService(IEnumerable<SystemTelemetrySnapshot> snapshots)
        {
            _snapshots = new Queue<SystemTelemetrySnapshot>(snapshots);
        }

        public int CaptureCount { get; private set; }

        public async Task<SystemTelemetrySnapshot> CaptureAsync(CancellationToken cancellationToken = default)
        {
            await _lock.WaitAsync(cancellationToken);
            try
            {
                CaptureCount++;
                return _snapshots.Dequeue();
            }
            finally
            {
                _lock.Release();
            }
        }
    }

    private sealed class RecordingTelemetryHistoryService : ISystemTelemetryHistoryService
    {
        private readonly List<SystemTelemetrySnapshot> _snapshots = [];

        public string HistoryFilePath => Path.Combine(Path.GetTempPath(), "burrowwin-test-telemetry.jsonl");

        public IReadOnlyList<SystemTelemetrySnapshot> RecordedSnapshots => _snapshots;

        public Task RecordAsync(SystemTelemetrySnapshot snapshot, CancellationToken cancellationToken = default)
        {
            _snapshots.Add(snapshot);
            return Task.CompletedTask;
        }

        public Task<IReadOnlyList<SystemTelemetrySnapshot>> ReadRecentAsync(int limit, CancellationToken cancellationToken = default)
        {
            return Task.FromResult<IReadOnlyList<SystemTelemetrySnapshot>>(_snapshots.TakeLast(limit).Reverse().ToArray());
        }
    }
}
