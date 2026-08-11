using System.ComponentModel;
using System.Security;
using BurrowWin.Models;

namespace BurrowWin.Services;

public sealed class GpuTelemetryBackoffProvider : IGpuTelemetryProvider
{
    public static readonly TimeSpan DefaultInitialBackoff = TimeSpan.FromSeconds(30);
    public static readonly TimeSpan DefaultMaximumBackoff = TimeSpan.FromMinutes(5);

    private readonly IGpuTelemetryProvider _inner;
    private readonly Func<DateTimeOffset> _utcNow;
    private readonly TimeSpan _initialBackoff;
    private readonly TimeSpan _maximumBackoff;
    private readonly object _sync = new();

    private int _consecutiveFailures;
    private DateTimeOffset _nextAttemptAt = DateTimeOffset.MinValue;
    private GpuTelemetrySample _lastUnavailable = GpuTelemetrySample.Unavailable("GPU telemetry has not been sampled yet.");

    public GpuTelemetryBackoffProvider(IGpuTelemetryProvider inner)
        : this(inner, () => DateTimeOffset.UtcNow, DefaultInitialBackoff, DefaultMaximumBackoff)
    {
    }

    public GpuTelemetryBackoffProvider(
        IGpuTelemetryProvider inner,
        Func<DateTimeOffset> utcNow,
        TimeSpan initialBackoff,
        TimeSpan maximumBackoff)
    {
        ArgumentNullException.ThrowIfNull(inner);
        ArgumentNullException.ThrowIfNull(utcNow);

        if (initialBackoff <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(initialBackoff));
        }

        if (maximumBackoff < initialBackoff)
        {
            throw new ArgumentOutOfRangeException(nameof(maximumBackoff));
        }

        _inner = inner;
        _utcNow = utcNow;
        _initialBackoff = initialBackoff;
        _maximumBackoff = maximumBackoff;
    }

    public GpuTelemetrySample Capture()
    {
        lock (_sync)
        {
            var now = _utcNow();
            if (now < _nextAttemptAt)
            {
                return _lastUnavailable with { RetryAfter = _nextAttemptAt };
            }

            GpuTelemetrySample sample;
            try
            {
                sample = _inner.Capture();
            }
            catch (Exception ex) when (IsExpectedCounterFailure(ex))
            {
                sample = GpuTelemetrySample.Unavailable($"GPU performance counters are inaccessible ({ex.GetType().Name}).");
            }

            if (sample.IsAvailable)
            {
                _consecutiveFailures = 0;
                _nextAttemptAt = DateTimeOffset.MinValue;
                return sample with { RetryAfter = null };
            }

            _consecutiveFailures++;
            _nextAttemptAt = now + CalculateBackoff(_consecutiveFailures);
            _lastUnavailable = sample with { RetryAfter = _nextAttemptAt };
            return _lastUnavailable;
        }
    }

    private TimeSpan CalculateBackoff(int consecutiveFailures)
    {
        var delayTicks = _initialBackoff.Ticks;
        for (var index = 1; index < consecutiveFailures && delayTicks < _maximumBackoff.Ticks; index++)
        {
            delayTicks = delayTicks > _maximumBackoff.Ticks / 2
                ? _maximumBackoff.Ticks
                : delayTicks * 2;
        }

        return TimeSpan.FromTicks(delayTicks);
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
