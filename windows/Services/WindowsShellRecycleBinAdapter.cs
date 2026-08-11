using System.Runtime.InteropServices;
using BurrowWin.Models;

namespace BurrowWin.Services;

/// <summary>
/// Uses IFileOperation with FOFX_RECYCLEONDELETE. The Shell operation is deliberately
/// non-interactive and has no permanent-delete fallback.
/// </summary>
public sealed class WindowsShellRecycleBinAdapter : IRecycleBinAdapter
{
    public Task<RecycleBinAdapterResult> RecycleAsync(string canonicalPath, DeletionItemType itemType)
    {
        var completion = new TaskCompletionSource<RecycleBinAdapterResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            try
            {
                completion.SetResult(RecycleCore(canonicalPath, itemType));
            }
            catch (Exception ex)
            {
                completion.SetResult(new RecycleBinAdapterResult(false, ex.Message));
            }
        })
        {
            IsBackground = true,
            Name = "BurrowWin Recycle Bin operation"
        };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        return completion.Task;
    }

    private static RecycleBinAdapterResult RecycleCore(string canonicalPath, DeletionItemType itemType)
    {
        IFileOperation? operation = null;
        IShellItem? item = null;
        try
        {
            operation = (IFileOperation)(object)new FileOperationComObject();
            operation.SetOperationFlags(
                FileOperationFlags.Silent |
                FileOperationFlags.NoConfirmation |
                FileOperationFlags.AllowUndo |
                FileOperationFlags.NoErrorUi |
                FileOperationFlags.RecycleOnDelete |
                FileOperationFlags.EarlyFailure);

            var shellItemId = typeof(IShellItem).GUID;
            SHCreateItemFromParsingName(canonicalPath, IntPtr.Zero, ref shellItemId, out item);
            operation.DeleteItem(item, IntPtr.Zero);
            operation.PerformOperations();
            if (operation.GetAnyOperationsAborted())
            {
                return new RecycleBinAdapterResult(false, "The Windows Shell aborted the Recycle Bin operation.");
            }

            var noun = itemType == DeletionItemType.Directory ? "Directory" : "File";
            return new RecycleBinAdapterResult(
                true,
                $"{noun} moved to the Windows Recycle Bin. Exact recovery locator is unavailable.");
        }
        finally
        {
            if (item is not null && Marshal.IsComObject(item))
            {
                Marshal.FinalReleaseComObject(item);
            }

            if (operation is not null && Marshal.IsComObject(operation))
            {
                Marshal.FinalReleaseComObject(operation);
            }
        }
    }

    [Flags]
    private enum FileOperationFlags : uint
    {
        Silent = 0x0004,
        NoConfirmation = 0x0010,
        AllowUndo = 0x0040,
        NoErrorUi = 0x0400,
        RecycleOnDelete = 0x00080000,
        EarlyFailure = 0x00100000
    }

    [ComImport]
    [Guid("3AD05575-8857-4850-9277-11B85BDB8E09")]
    [ClassInterface(ClassInterfaceType.None)]
    private sealed class FileOperationComObject
    {
    }

    [ComImport]
    [Guid("947AAB5F-0A5C-4C13-B4D6-4BF7836FC9F8")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFileOperation
    {
        uint Advise(IntPtr progressSink);
        void Unadvise(uint cookie);
        void SetOperationFlags(FileOperationFlags operationFlags);
        void SetProgressMessage([MarshalAs(UnmanagedType.LPWStr)] string message);
        void SetProgressDialog([MarshalAs(UnmanagedType.Interface)] object progressDialog);
        void SetProperties([MarshalAs(UnmanagedType.Interface)] object properties);
        void SetOwnerWindow(uint ownerWindow);
        void ApplyPropertiesToItem(IShellItem item);
        void ApplyPropertiesToItems([MarshalAs(UnmanagedType.IUnknown)] object items);
        void RenameItem(IShellItem item, [MarshalAs(UnmanagedType.LPWStr)] string newName, IntPtr progressSink);
        void RenameItems([MarshalAs(UnmanagedType.IUnknown)] object items, [MarshalAs(UnmanagedType.LPWStr)] string newName);
        void MoveItem(IShellItem item, IShellItem destinationFolder, [MarshalAs(UnmanagedType.LPWStr)] string newName, IntPtr progressSink);
        void MoveItems([MarshalAs(UnmanagedType.IUnknown)] object items, IShellItem destinationFolder);
        void CopyItem(IShellItem item, IShellItem destinationFolder, [MarshalAs(UnmanagedType.LPWStr)] string copyName, IntPtr progressSink);
        void CopyItems([MarshalAs(UnmanagedType.IUnknown)] object items, IShellItem destinationFolder);
        void DeleteItem(IShellItem item, IntPtr progressSink);
        void DeleteItems([MarshalAs(UnmanagedType.IUnknown)] object items);
        uint NewItem(IShellItem destinationFolder, FileAttributes fileAttributes, [MarshalAs(UnmanagedType.LPWStr)] string name, [MarshalAs(UnmanagedType.LPWStr)] string templateName, IntPtr progressSink);
        void PerformOperations();
        [return: MarshalAs(UnmanagedType.Bool)]
        bool GetAnyOperationsAborted();
    }

    [ComImport]
    [Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItem
    {
        void BindToHandler(IntPtr bindContext, ref Guid handlerId, ref Guid interfaceId, out IntPtr result);
        void GetParent(out IShellItem parent);
        void GetDisplayName(uint displayNameType, out IntPtr name);
        void GetAttributes(uint mask, out uint attributes);
        void Compare(IShellItem other, uint hint, out int order);
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    private static extern void SHCreateItemFromParsingName(
        [MarshalAs(UnmanagedType.LPWStr)] string path,
        IntPtr bindContext,
        ref Guid interfaceId,
        [MarshalAs(UnmanagedType.Interface)] out IShellItem shellItem);
}
