using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using WinRT.Interop;
using BurrowWin.ViewModels;
using BurrowWin.Views;

namespace BurrowWin.Services;

public sealed class WindowsTrayIconService : ITrayIconService
{
    private const uint TrayIconId = 1;
    private const uint SubclassId = 1;
    private const uint NimAdd = 0x00000000;
    private const uint NimModify = 0x00000001;
    private const uint NimDelete = 0x00000002;
    private const uint NifMessage = 0x00000001;
    private const uint NifIcon = 0x00000002;
    private const uint NifTip = 0x00000004;
    private const uint ImageIcon = 1;
    private const uint LoadFromFile = 0x00000010;
    private const uint LoadDefaultSize = 0x00000040;
    private const uint MfString = 0x00000000;
    private const uint MfSeparator = 0x00000800;
    private const uint MfDisabled = 0x00000002;
    private const uint MfGrayed = 0x00000001;
    private const uint TpmRightButton = 0x0002;
    private const uint TpmReturnCommand = 0x0100;
    private const uint TpmNoNotify = 0x0080;
    private const int TrayCallbackMessage = 0x8000 + 37;
    private const int WmLButtonUp = 0x0202;
    private const int WmLButtonDoubleClick = 0x0203;
    private const int WmRButtonUp = 0x0205;
    private const int WmContextMenu = 0x007B;
    private const int SwRestore = 9;
    private const int MenuHud = 1000;
    private const int MenuOpen = 1001;
    private const int MenuStatus = 1002;
    private const int MenuHistory = 1003;
    private const int MenuActivity = 1004;
    private const int MenuClean = 1005;
    private const int MenuOptimize = 1006;
    private const int MenuSettings = 1007;
    private const int MenuExit = 1099;
    private static readonly uint TaskbarCreatedMessage = RegisterWindowMessage("TaskbarCreated");

    private readonly ISystemTelemetrySamplerService _telemetrySamplerService;
    private readonly IOperationHistoryService _operationHistoryService;
    private readonly ShellViewModel _shellViewModel;
    private readonly SubclassProc _subclassProc;
    private Timer? _refreshTimer;
    private Window? _mainWindow;
    private TrayHudWindow? _trayHudWindow;
    private IntPtr _windowHandle;
    private IntPtr _iconHandle;
    private bool _ownsIcon;
    private bool _isInitialized;
    private bool _isSubclassed;

    public WindowsTrayIconService(
        ISystemTelemetrySamplerService telemetrySamplerService,
        IOperationHistoryService operationHistoryService,
        ShellViewModel shellViewModel)
    {
        _telemetrySamplerService = telemetrySamplerService;
        _operationHistoryService = operationHistoryService;
        _shellViewModel = shellViewModel;
        _subclassProc = WindowSubclassProc;
    }

    public void Initialize(Window mainWindow)
    {
        if (_isInitialized)
        {
            return;
        }

        _mainWindow = mainWindow;
        _windowHandle = WindowNative.GetWindowHandle(mainWindow);
        InstallMessageHook();
        _iconHandle = LoadTrayIcon();
        TryShellNotifyIcon(NimAdd, BuildNotifyIconData(NifMessage | NifIcon | NifTip), "Tray icon add");
        _isInitialized = true;

        _refreshTimer = new Timer(_ => UpdateTooltip(), null, TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(30));
    }

    public void ShowHudForDiagnostics(int x, int y)
    {
        ShowTrayHud(x, y);
    }

    public void Dispose()
    {
        _refreshTimer?.Dispose();
        _refreshTimer = null;

        if (_isInitialized)
        {
            TryShellNotifyIcon(NimDelete, BuildNotifyIconData(0), "Tray icon delete");
        }

        RemoveMessageHook();
        _trayHudWindow?.Close();
        _trayHudWindow = null;
        _isInitialized = false;
        _mainWindow = null;
        _windowHandle = IntPtr.Zero;

        if (_ownsIcon && _iconHandle != IntPtr.Zero)
        {
            DestroyIcon(_iconHandle);
        }

        _iconHandle = IntPtr.Zero;
        _ownsIcon = false;
    }

    private void UpdateTooltip()
    {
        if (!_isInitialized)
        {
            return;
        }

        TryShellNotifyIcon(NimModify, BuildNotifyIconData(NifTip), "Tray tooltip update");
    }

    private void InstallMessageHook()
    {
        if (_isSubclassed || _windowHandle == IntPtr.Zero)
        {
            return;
        }

        _isSubclassed = SetWindowSubclass(_windowHandle, _subclassProc, new UIntPtr(SubclassId), UIntPtr.Zero);
        if (!_isSubclassed)
        {
            WriteTrayDiagnostic($"Tray message hook failed: Win32Error={Marshal.GetLastWin32Error()}");
        }
    }

    private void RemoveMessageHook()
    {
        if (!_isSubclassed || _windowHandle == IntPtr.Zero)
        {
            return;
        }

        RemoveWindowSubclass(_windowHandle, _subclassProc, new UIntPtr(SubclassId));
        _isSubclassed = false;
    }

    private IntPtr WindowSubclassProc(
        IntPtr windowHandle,
        uint message,
        IntPtr wParam,
        IntPtr lParam,
        UIntPtr subclassId,
        UIntPtr referenceData)
    {
        if (message == TaskbarCreatedMessage && _isInitialized)
        {
            TryShellNotifyIcon(NimAdd, BuildNotifyIconData(NifMessage | NifIcon | NifTip), "Tray icon restore");
            return IntPtr.Zero;
        }

        if (message == TrayCallbackMessage && wParam.ToInt64() == TrayIconId)
        {
            HandleTrayMessage(lParam);
            return IntPtr.Zero;
        }

        return DefSubclassProc(windowHandle, message, wParam, lParam);
    }

    private void HandleTrayMessage(IntPtr lParam)
    {
        var message = unchecked((int)lParam.ToInt64());
        switch (message)
        {
            case WmLButtonUp:
            case WmLButtonDoubleClick:
                ShowTrayHud();
                break;
            case WmRButtonUp:
            case WmContextMenu:
                ShowTrayMenu();
                break;
        }
    }

    private void ShowTrayMenu()
    {
        if (_windowHandle == IntPtr.Zero)
        {
            return;
        }

        if (!GetCursorPos(out var cursorPosition))
        {
            return;
        }

        var menuHandle = CreatePopupMenu();
        if (menuHandle == IntPtr.Zero)
        {
            return;
        }

        try
        {
            BuildTrayMenu(menuHandle);
            SetForegroundWindow(_windowHandle);
            var command = TrackPopupMenuEx(
                menuHandle,
                TpmRightButton | TpmReturnCommand | TpmNoNotify,
                cursorPosition.X,
                cursorPosition.Y,
                _windowHandle,
                IntPtr.Zero);
            ExecuteMenuCommand(command);
        }
        finally
        {
            DestroyMenu(menuHandle);
        }
    }

    private void BuildTrayMenu(IntPtr menuHandle)
    {
        var snapshot = _telemetrySamplerService.LatestSnapshot;
        AppendMenu(menuHandle, MfString | MfDisabled | MfGrayed, UIntPtr.Zero, "Burrow");
        AppendMenu(menuHandle, MfString | MfDisabled | MfGrayed, UIntPtr.Zero, TrayIconTextFormatter.BuildHealthLine(snapshot));
        AppendMenu(menuHandle, MfString | MfDisabled | MfGrayed, UIntPtr.Zero, TrayIconTextFormatter.BuildResourceLine(snapshot));
        AppendMenu(menuHandle, MfString | MfDisabled | MfGrayed, UIntPtr.Zero, TrayIconTextFormatter.BuildNetworkLine(snapshot));
        AppendMenu(menuHandle, MfString | MfDisabled | MfGrayed, UIntPtr.Zero, TrayIconTextFormatter.BuildSampleLine(snapshot));
        AppendMenu(menuHandle, MfSeparator, UIntPtr.Zero, null);
        AppendMenu(menuHandle, MfString, new UIntPtr(MenuHud), "Show Tray HUD");
        AppendMenu(menuHandle, MfString, new UIntPtr(MenuOpen), "Open Burrow");
        AppendMenu(menuHandle, MfString, new UIntPtr(MenuStatus), "Status");
        AppendMenu(menuHandle, MfString, new UIntPtr(MenuHistory), "History");
        AppendMenu(menuHandle, MfString, new UIntPtr(MenuActivity), "Activity");
        AppendMenu(menuHandle, MfSeparator, UIntPtr.Zero, null);
        AppendMenu(menuHandle, MfString, new UIntPtr(MenuClean), "Clean");
        AppendMenu(menuHandle, MfString, new UIntPtr(MenuOptimize), "Optimize");
        AppendMenu(menuHandle, MfString, new UIntPtr(MenuSettings), "Settings");
        AppendMenu(menuHandle, MfSeparator, UIntPtr.Zero, null);
        AppendMenu(menuHandle, MfString, new UIntPtr(MenuExit), "Exit Burrow");
    }

    private void ExecuteMenuCommand(int command)
    {
        switch (command)
        {
            case MenuHud:
                ShowTrayHud();
                break;
            case MenuOpen:
                ShowAndNavigate(null);
                break;
            case MenuStatus:
                ShowAndNavigate("status");
                break;
            case MenuHistory:
                ShowAndNavigate("history");
                break;
            case MenuActivity:
                ShowAndNavigate("activity");
                break;
            case MenuClean:
                ShowAndNavigate("clean");
                break;
            case MenuOptimize:
                ShowAndNavigate("optimize");
                break;
            case MenuSettings:
                ShowAndNavigate("settings");
                break;
            case MenuExit:
                CloseMainWindow();
                break;
        }
    }

    private void ShowTrayHud()
    {
        if (GetCursorPos(out var cursorPosition))
        {
            ShowTrayHud(cursorPosition.X, cursorPosition.Y);
            return;
        }

        ShowTrayHud(640, 720);
    }

    private void ShowTrayHud(int x, int y)
    {
        var mainWindow = _mainWindow;
        if (mainWindow is null)
        {
            return;
        }

        mainWindow.DispatcherQueue.TryEnqueue(async () =>
        {
            try
            {
                if (_trayHudWindow is null)
                {
                    _trayHudWindow = new TrayHudWindow(_telemetrySamplerService, _operationHistoryService, ShowAndNavigate);
                    _trayHudWindow.Closed += (_, _) => _trayHudWindow = null;
                }

                await _trayHudWindow.ShowNearAsync(x, y);
            }
            catch (Exception ex)
            {
                WriteTrayDiagnostic($"Tray HUD show failed: {ex.GetType().Name}: {ex.Message}");
            }
        });
    }

    private void ShowAndNavigate(string? route)
    {
        var mainWindow = _mainWindow;
        if (mainWindow is null)
        {
            return;
        }

        mainWindow.DispatcherQueue.TryEnqueue(() =>
        {
            if (_windowHandle != IntPtr.Zero)
            {
                ShowWindow(_windowHandle, SwRestore);
                SetForegroundWindow(_windowHandle);
            }

            mainWindow.Activate();

            if (!string.IsNullOrWhiteSpace(route))
            {
                _shellViewModel.NavigateCommand.Execute(route);
            }
        });
    }

    private void CloseMainWindow()
    {
        var mainWindow = _mainWindow;
        if (mainWindow is null)
        {
            return;
        }

        mainWindow.DispatcherQueue.TryEnqueue(mainWindow.Close);
    }

    private NotifyIconData BuildNotifyIconData(uint flags)
    {
        return new NotifyIconData
        {
            Size = (uint)Marshal.SizeOf<NotifyIconData>(),
            WindowHandle = _windowHandle,
            Id = TrayIconId,
            Flags = flags,
            CallbackMessage = TrayCallbackMessage,
            IconHandle = _iconHandle,
            Tip = TrayIconTextFormatter.BuildTooltip(_telemetrySamplerService.LatestSnapshot),
            Info = string.Empty,
            InfoTitle = string.Empty
        };
    }

    private IntPtr LoadTrayIcon()
    {
        var iconPath = Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico");
        if (File.Exists(iconPath))
        {
            var handle = LoadImage(IntPtr.Zero, iconPath, ImageIcon, 0, 0, LoadFromFile | LoadDefaultSize);
            if (handle != IntPtr.Zero)
            {
                _ownsIcon = true;
                return handle;
            }
        }

        _ownsIcon = false;
        return LoadIcon(IntPtr.Zero, new IntPtr(32512));
    }

    private static bool TryShellNotifyIcon(uint message, NotifyIconData data, string action)
    {
        try
        {
            if (ShellNotifyIcon(message, data))
            {
                return true;
            }

            WriteTrayDiagnostic($"{action} failed: Win32Error={Marshal.GetLastWin32Error()}");
            return false;
        }
        catch (Exception ex)
        {
            WriteTrayDiagnostic($"{action} failed: {ex.GetType().Name}: {ex.Message}");
            return false;
        }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyIconData
    {
        public uint Size;
        public IntPtr WindowHandle;
        public uint Id;
        public uint Flags;
        public int CallbackMessage;
        public IntPtr IconHandle;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string Tip;

        public uint State;
        public uint StateMask;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string Info;

        public uint TimeoutOrVersion;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string InfoTitle;

        public uint InfoFlags;
        public Guid GuidItem;
        public IntPtr BalloonIconHandle;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativePoint
    {
        public int X;
        public int Y;
    }

    private delegate IntPtr SubclassProc(
        IntPtr windowHandle,
        uint message,
        IntPtr wParam,
        IntPtr lParam,
        UIntPtr subclassId,
        UIntPtr referenceData);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, EntryPoint = "Shell_NotifyIconW", SetLastError = true)]
    private static extern bool ShellNotifyIcon(uint message, in NotifyIconData data);

    [DllImport("comctl32.dll", SetLastError = true)]
    private static extern bool SetWindowSubclass(IntPtr windowHandle, SubclassProc subclassProc, UIntPtr subclassId, UIntPtr referenceData);

    [DllImport("comctl32.dll", SetLastError = true)]
    private static extern bool RemoveWindowSubclass(IntPtr windowHandle, SubclassProc subclassProc, UIntPtr subclassId);

    [DllImport("comctl32.dll", SetLastError = true)]
    private static extern IntPtr DefSubclassProc(IntPtr windowHandle, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr LoadImage(IntPtr instance, string name, uint type, int desiredWidth, int desiredHeight, uint load);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr LoadIcon(IntPtr instance, IntPtr iconName);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyIcon(IntPtr iconHandle);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint RegisterWindowMessage(string message);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreatePopupMenu();

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool AppendMenu(IntPtr menuHandle, uint flags, UIntPtr itemId, string? itemText);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern int TrackPopupMenuEx(IntPtr menuHandle, uint flags, int x, int y, IntPtr windowHandle, IntPtr parameters);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyMenu(IntPtr menuHandle);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetCursorPos(out NativePoint point);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetForegroundWindow(IntPtr windowHandle);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool ShowWindow(IntPtr windowHandle, int commandShow);

    private static void WriteTrayDiagnostic(string message)
    {
        try
        {
            var directory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "BurrowWin");
            Directory.CreateDirectory(directory);
            File.AppendAllText(
                Path.Combine(directory, "tray-hud-diagnostic.log"),
                $"{DateTimeOffset.Now:O} {message}{Environment.NewLine}");
        }
        catch
        {
        }
    }
}
