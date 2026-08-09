using System.Text.Json;
using BurrowWin.Models;

namespace BurrowWin.Services;

public sealed class JsonDeletionReceiptStore : IDeletionReceiptStore
{
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        WriteIndented = false
    };

    private readonly SemaphoreSlim _fileLock = new(1, 1);

    public JsonDeletionReceiptStore()
        : this(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "BurrowWin",
            "deletion-receipts.jsonl"))
    {
    }

    public JsonDeletionReceiptStore(string receiptFilePath)
    {
        ReceiptFilePath = receiptFilePath;
    }

    public string ReceiptFilePath { get; }

    public async Task AppendAsync(DeletionReceipt receipt, CancellationToken cancellationToken = default)
    {
        var directory = Path.GetDirectoryName(ReceiptFilePath);
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }

        var line = JsonSerializer.Serialize(receipt, SerializerOptions) + Environment.NewLine;
        await _fileLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await File.AppendAllTextAsync(ReceiptFilePath, line, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _fileLock.Release();
        }
    }
}
