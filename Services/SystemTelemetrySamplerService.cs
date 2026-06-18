using BurrowWin.Models;
using Microsoft.Extensions.Hosting;

namespace BurrowWin.Services;

public sealed class SystemTelemetrySamplerService : BackgroundService, ISystemTelemetrySamplerService
{
    public static readonly TimeSpan DefaultSamplingInterval = TimeSpan.FromSeconds(60);

    private readonly ISystemTelemetryService _telemetryService;
    private readonly ISystemTelemetryHistoryService _historyService;
    private readonly Func<TimeSpan> _samplingIntervalProvider;
    private readonly SemaphoreSlim _sampleLock = new(1, 1);

    public SystemTelemetrySamplerService(
        ISystemTelemetryService telemetryService,
        ISystemTelemetryHistoryService historyService,
        IApplicationSettingsService settingsService)
        : this(
            telemetryService,
            historyService,
            () => TimeSpan.FromSeconds(settingsService.Current.SamplingIntervalSeconds))
    {
    }

    public SystemTelemetrySamplerService(
        ISystemTelemetryService telemetryService,
        ISystemTelemetryHistoryService historyService,
        TimeSpan samplingInterval)
        : this(telemetryService, historyService, () => samplingInterval)
    {
    }

    private SystemTelemetrySamplerService(
        ISystemTelemetryService telemetryService,
        ISystemTelemetryHistoryService historyService,
        Func<TimeSpan> samplingIntervalProvider)
    {
        _telemetryService = telemetryService;
        _historyService = historyService;
        _samplingIntervalProvider = samplingIntervalProvider;
    }

    public TimeSpan SamplingInterval
    {
        get
        {
            var interval = _samplingIntervalProvider();
            return interval <= TimeSpan.Zero ? DefaultSamplingInterval : interval;
        }
    }

    public string Source => "windows_native_sampler";

    public SystemTelemetrySnapshot? LatestSnapshot { get; private set; }

    public async Task<SystemTelemetrySnapshot> SampleNowAsync(CancellationToken cancellationToken = default)
    {
        await _sampleLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var snapshot = await _telemetryService.CaptureAsync(cancellationToken).ConfigureAwait(false);
            await _historyService.RecordAsync(snapshot, cancellationToken).ConfigureAwait(false);
            LatestSnapshot = snapshot;
            return snapshot;
        }
        finally
        {
            _sampleLock.Release();
        }
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await SampleNowAsync(stoppingToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch
            {
                // Keep Burrow's background sampler alive even if one telemetry read fails.
            }

            try
            {
                await Task.Delay(SamplingInterval, stoppingToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
        }
    }
}
