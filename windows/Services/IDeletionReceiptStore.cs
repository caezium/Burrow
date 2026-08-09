using BurrowWin.Models;

namespace BurrowWin.Services;

public interface IDeletionReceiptStore
{
    string ReceiptFilePath { get; }

    Task AppendAsync(DeletionReceipt receipt, CancellationToken cancellationToken = default);
}
