using BurrowWin.Models;
using BurrowWin.Services;
using Xunit;

namespace BurrowWin.Tests;

public sealed class RecycleBinDeletionServiceTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "BurrowDeletion", Guid.NewGuid().ToString("N"));
    private readonly FakeWindowsFileSystemInspector _fileSystem = new();
    private readonly FakeRecycleBinAdapter _recycleBin = new();
    private readonly RecordingReceiptStore _receipts = new();

    public RecycleBinDeletionServiceTests()
    {
        Directory.CreateDirectory(_root);
        _fileSystem.Set(_root, DeletionItemType.Directory);
    }

    [Fact]
    public async Task DeleteAsync_RecyclesAuthorizedTargetAndRecordsHonestReceipt()
    {
        var target = Path.Combine(_root, "artifact.bin");
        _fileSystem.Set(target, DeletionItemType.File, sizeBytes: 12);
        var request = Request(target, 12, FlowSafetyValidation.Allow(12));

        var result = await Service().DeleteAsync(request);

        Assert.Equal(SafeDeletionStatus.Recycled, result.Status);
        Assert.Equal(12, result.RecycledBytes);
        Assert.Single(_recycleBin.Paths);
        var receipt = Assert.Single(_receipts.Receipts);
        Assert.Equal(target, receipt.OriginalPath);
        Assert.Equal(request.OperationId, receipt.OperationId);
        Assert.Equal(SafeDeletionStatus.Recycled, receipt.Disposition);
        Assert.False(receipt.ExactRecoveryLocatorAvailable);
        Assert.Null(receipt.RecoveryLocator);
    }

    [Fact]
    public async Task DeleteAsync_BackendFailureNeverFallsBackToPermanentDeletion()
    {
        var target = Path.Combine(_root, "artifact.bin");
        _fileSystem.Set(target, DeletionItemType.File, sizeBytes: 12);
        _recycleBin.NextResult = new RecycleBinAdapterResult(false, "Recycle Bin unavailable");

        var result = await Service().DeleteAsync(Request(target, 12, FlowSafetyValidation.Allow(12)));

        Assert.Equal(SafeDeletionStatus.Failed, result.Status);
        Assert.Equal(0, result.RecycledBytes);
        Assert.Single(_recycleBin.Paths);
        Assert.Equal("Recycle Bin unavailable", result.Receipt.FailureOrRejectionReason);
    }

    [Fact]
    public async Task DeleteAsync_MissingPathIsAlreadyAbsentAndFreesNoBytes()
    {
        var target = Path.Combine(_root, "missing.bin");

        var result = await Service().DeleteAsync(Request(target, 99, FlowSafetyValidation.Allow()));

        Assert.Equal(SafeDeletionStatus.AlreadyAbsent, result.Status);
        Assert.Equal(0, result.RecycledBytes);
        Assert.Empty(_recycleBin.Paths);
        Assert.Null(result.ObservedSizeBytes);
    }

    [Fact]
    public async Task DeleteAsync_RequiresExactAuthorizationAtServiceBoundary()
    {
        var target = Path.Combine(_root, "artifact.bin");
        var other = Path.Combine(_root, "other.bin");
        _fileSystem.Set(target, DeletionItemType.File, sizeBytes: 12);
        var descriptor = Descriptor(target, 12);
        var otherDescriptor = Descriptor(other, 12);
        var authorization = ConfirmedDeletionAuthorization.Confirm(DestructiveFlow.Installer, [otherDescriptor]);
        var request = new SafeDeletionRequest(
            descriptor,
            Path.GetFullPath(target),
            authorization.OperationId,
            authorization,
            FlowSafetyValidation.Allow(12));

        var result = await Service().DeleteAsync(request);

        Assert.Equal(SafeDeletionStatus.Rejected, result.Status);
        Assert.Empty(_recycleBin.Paths);
    }

    [Fact]
    public async Task DeleteAsync_CancellationBeforeShellReturnsStructuredCancelledResult()
    {
        var target = Path.Combine(_root, "artifact.bin");
        _fileSystem.Set(target, DeletionItemType.File, sizeBytes: 12);
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        var result = await Service().DeleteAsync(
            Request(target, 12, FlowSafetyValidation.Allow(12)),
            cancellation.Token);

        Assert.Equal(SafeDeletionStatus.Cancelled, result.Status);
        Assert.Empty(_recycleBin.Paths);
        Assert.Equal(SafeDeletionStatus.Cancelled, Assert.Single(_receipts.Receipts).Disposition);
    }

    [Fact]
    public async Task DeleteAsync_RejectsFlowSpecificValidationFailure()
    {
        var target = Path.Combine(_root, "artifact.bin");
        _fileSystem.Set(target, DeletionItemType.File, sizeBytes: 12);

        var result = await Service().DeleteAsync(Request(
            target,
            12,
            FlowSafetyValidation.Reject("changed", "Candidate changed after preview.")));

        Assert.Equal(SafeDeletionStatus.Rejected, result.Status);
        Assert.Empty(_recycleBin.Paths);
    }

    public void Dispose()
    {
        Directory.Delete(_root, recursive: true);
    }

    private RecycleBinDeletionService Service()
    {
        var policy = new WindowsPathSafetyPolicy(_fileSystem, []);
        return new RecycleBinDeletionService(policy, _fileSystem, _recycleBin, _receipts);
    }

    private SafeDeletionRequest Request(string target, long size, FlowSafetyValidation flowValidation)
    {
        var descriptor = Descriptor(target, size);
        var authorization = ConfirmedDeletionAuthorization.Confirm(DestructiveFlow.Installer, [descriptor]);
        return new SafeDeletionRequest(
            descriptor,
            Path.GetFullPath(target),
            authorization.OperationId,
            authorization,
            flowValidation);
    }

    private DeletionCandidateDescriptor Descriptor(string target, long size) =>
        new(
            target,
            _root,
            DestructiveFlow.Installer,
            "Archive",
            DeletionItemType.File,
            size);

    private sealed class FakeRecycleBinAdapter : IRecycleBinAdapter
    {
        public List<string> Paths { get; } = [];

        public RecycleBinAdapterResult NextResult { get; set; } = new(true, "Recycled");

        public Task<RecycleBinAdapterResult> RecycleAsync(string canonicalPath, DeletionItemType itemType)
        {
            Paths.Add(canonicalPath);
            return Task.FromResult(NextResult);
        }
    }

    private sealed class RecordingReceiptStore : IDeletionReceiptStore
    {
        public string ReceiptFilePath => "memory://receipts";

        public List<DeletionReceipt> Receipts { get; } = [];

        public Task AppendAsync(DeletionReceipt receipt, CancellationToken cancellationToken = default)
        {
            Receipts.Add(receipt);
            return Task.CompletedTask;
        }
    }
}
