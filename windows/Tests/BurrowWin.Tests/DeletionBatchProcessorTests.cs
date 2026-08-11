using BurrowWin.Models;
using BurrowWin.Services;
using Xunit;

namespace BurrowWin.Tests;

public sealed class DeletionBatchProcessorTests
{
    [Fact]
    public async Task RunAsync_CancellationBeforeFirstItemStartsNoWork()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        var started = new List<string>();

        var batch = await DeletionBatchProcessor.RunAsync(
            new[] { "one", "two" },
            "op-before",
            item => item,
            item =>
            {
                started.Add(item);
                return Task.FromResult(Result(item, SafeDeletionStatus.Recycled, 1));
            },
            null,
            cancellation.Token);

        Assert.True(batch.Cancelled);
        Assert.Equal(DeletionBatchOutcome.Cancelled, batch.Outcome);
        Assert.Equal(0, batch.ProcessedCount);
        Assert.Empty(batch.ItemResults);
        Assert.Empty(started);
        Assert.Equal("one", batch.InProgressPathWhenCancelled);
    }

    [Fact]
    public async Task RunAsync_CancellationAfterCompletedItemPreservesResultAndStopsLaterWork()
    {
        using var cancellation = new CancellationTokenSource();
        var started = new List<string>();

        var batch = await DeletionBatchProcessor.RunAsync(
            new[] { "one", "two", "three" },
            "op-after",
            item => item,
            item =>
            {
                started.Add(item);
                cancellation.Cancel();
                return Task.FromResult(Result(item, SafeDeletionStatus.Recycled, 10));
            },
            null,
            cancellation.Token);

        Assert.Equal(new[] { "one" }, started);
        Assert.True(batch.Cancelled);
        Assert.Equal(1, batch.ProcessedCount);
        Assert.Equal(1, batch.RecycledCount);
        Assert.Equal(10, batch.RecycledBytes);
        Assert.Single(batch.ItemResults);
        Assert.NotEqual(100, batch.CompletionPercent);
    }

    [Fact]
    public async Task RunAsync_CancellationDuringActiveItemWaitsForObservableOutcome()
    {
        using var cancellation = new CancellationTokenSource();
        var started = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var startedPaths = new List<string>();

        var running = DeletionBatchProcessor.RunAsync(
            new[] { "one", "two" },
            "op-active",
            item => item,
            async item =>
            {
                startedPaths.Add(item);
                started.SetResult(true);
                await release.Task;
                return Result(item, SafeDeletionStatus.Recycled, 5);
            },
            null,
            cancellation.Token);

        await started.Task;
        cancellation.Cancel();
        Assert.False(running.IsCompleted);
        release.SetResult(true);
        var batch = await running;

        Assert.Equal(new[] { "one" }, startedPaths);
        Assert.True(batch.Cancelled);
        Assert.Equal(1, batch.RecycledCount);
        Assert.Single(batch.ItemResults);
        Assert.Equal("one", batch.InProgressPathWhenCancelled);
    }

    [Fact]
    public async Task RunAsync_ProgressIsMonotonicAndMatchesPartialFinalResult()
    {
        var progress = new List<DeletionProgress>();
        var scripted = new Dictionary<string, SafeDeletionResult>
        {
            ["one"] = Result("one", SafeDeletionStatus.Recycled, 10),
            ["two"] = Result("two", SafeDeletionStatus.AlreadyAbsent, null, expected: 20),
            ["three"] = Result("three", SafeDeletionStatus.Failed, 30)
        };

        var batch = await DeletionBatchProcessor.RunAsync(
            new[] { "one", "two", "three" },
            "op-progress",
            item => item,
            item => Task.FromResult(scripted[item]),
            new InlineProgress<DeletionProgress>(progress.Add),
            CancellationToken.None);

        Assert.Equal(DeletionBatchOutcome.PartialSuccess, batch.Outcome);
        Assert.Equal(3, batch.ProcessedCount);
        Assert.Equal(1, batch.RecycledCount);
        Assert.Equal(1, batch.AlreadyAbsentCount);
        Assert.Equal(1, batch.FailedCount);
        Assert.Equal(10, batch.RecycledBytes);
        Assert.NotEqual(100, batch.CompletionPercent);
        Assert.Equal(batch.ProcessedCount, progress[^1].ProcessedCount);
        Assert.Equal(batch.RecycledBytes, progress[^1].RecycledBytes);
        Assert.Equal(batch.FailedCount, progress[^1].FailedCount);
        Assert.All(progress.Zip(progress.Skip(1)), pair =>
        {
            Assert.True(pair.Second.ProcessedCount >= pair.First.ProcessedCount);
            Assert.True(pair.Second.CompletionPercent >= pair.First.CompletionPercent);
            Assert.InRange(pair.Second.CompletionPercent, 0, 100);
        });
    }

    [Fact]
    public async Task RunAsync_OneFailureDoesNotEraseOrStopOtherOutcomes()
    {
        var started = new List<string>();

        var batch = await DeletionBatchProcessor.RunAsync(
            new[] { "one", "two", "three" },
            "op-failure",
            item => item,
            item =>
            {
                started.Add(item);
                return Task.FromResult(item == "two"
                    ? Result(item, SafeDeletionStatus.Failed, 2)
                    : Result(item, SafeDeletionStatus.Recycled, 1));
            },
            null,
            CancellationToken.None);

        Assert.Equal(new[] { "one", "two", "three" }, started);
        Assert.Equal(3, batch.ItemResults.Count);
        Assert.Equal(2, batch.RecycledCount);
        Assert.Equal(1, batch.FailedCount);
        Assert.Equal(DeletionBatchOutcome.PartialSuccess, batch.Outcome);
    }

    private static SafeDeletionResult Result(
        string path,
        SafeDeletionStatus status,
        long? observed,
        long expected = 1)
    {
        var receipt = new DeletionReceipt(
            Guid.NewGuid().ToString("N"),
            "test-operation",
            path,
            path,
            DeletionItemType.File,
            expected,
            observed,
            status,
            DateTimeOffset.UtcNow,
            status == SafeDeletionStatus.Recycled ? DateTimeOffset.UtcNow : null,
            null,
            false,
            status is SafeDeletionStatus.Failed or SafeDeletionStatus.Rejected or SafeDeletionStatus.Cancelled ? "test" : null,
            DestructiveFlow.Installer,
            "test");
        return new SafeDeletionResult(path, path, status, status.ToString(), expected, observed, receipt);
    }
}
