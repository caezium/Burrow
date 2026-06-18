using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.UI.Xaml;
using BurrowWin.Models;
using BurrowWin.Services;
using BurrowWin.ViewModels;
using BurrowWin.Views;

namespace BurrowWin;

public partial class App : Application
{
    private readonly IHost _host;
    private Window? _window;
    private bool _exceptionLoggingRegistered;
    private bool _hostStartRequested;

    public App()
    {
        InitializeComponent();

        _host = Host.CreateDefaultBuilder()
            .ConfigureServices(services =>
            {
                services.AddSingleton<MainWindow>();
                services.AddSingleton<ShellPage>();
                services.AddSingleton<ShellViewModel>();
                services.AddSingleton<INavigationService, NavigationService>();
                services.AddSingleton<IApplicationSettingsService, JsonApplicationSettingsService>();
                services.AddSingleton<IStartupDiagnosticsService, LocalStartupDiagnosticsService>();
                services.AddSingleton<IMoleEngineProbe, SystemMoleEngineProbe>();
                services.AddSingleton<IOperationHistoryService, JsonOperationHistoryService>();
                services.AddSingleton<IMoleEngineService, MoleEngineService>();
                services.AddSingleton<ISystemTelemetryService, WindowsSystemTelemetryService>();
                services.AddSingleton<ISystemTelemetryHistoryService, JsonSystemTelemetryHistoryService>();
                services.AddSingleton<SystemTelemetrySamplerService>();
                services.AddSingleton<ISystemTelemetrySamplerService>(provider => provider.GetRequiredService<SystemTelemetrySamplerService>());
                services.AddHostedService(provider => provider.GetRequiredService<SystemTelemetrySamplerService>());
                services.AddSingleton<IDiskAnalyzerService, DiskAnalyzerService>();
                services.AddSingleton<IPurgeArtifactService, PurgeArtifactService>();
                services.AddSingleton<IInstallerCleanupService, InstallerCleanupService>();
                services.AddSingleton<IInstalledApplicationService, WindowsInstalledApplicationService>();
                services.AddSingleton<ITrayIconService, WindowsTrayIconService>();
                services.AddSingleton<LocalMcpServerService>();
                services.AddHostedService(provider => provider.GetRequiredService<LocalMcpServerService>());
                services.Configure<HostOptions>(options =>
                {
                    options.BackgroundServiceExceptionBehavior = BackgroundServiceExceptionBehavior.Ignore;
                });

                services.AddTransient<DashboardViewModel>();
                services.AddTransient<CleanupViewModel>();
                services.AddTransient<PurgeViewModel>();
                services.AddTransient<InstallerViewModel>();
                services.AddTransient<OptimizeViewModel>();
                services.AddTransient<UninstallViewModel>();
                services.AddTransient<AnalyzeViewModel>();
                services.AddTransient<HistoryViewModel>();
                services.AddTransient<ActivityViewModel>();
                services.AddTransient<SettingsViewModel>();
            })
            .Build();
    }

    public static T GetService<T>()
        where T : notnull
    {
        return ((App)Current)._host.Services.GetRequiredService<T>();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        var diagnostics = _host.Services.GetRequiredService<IStartupDiagnosticsService>();
        RegisterExceptionLogging(diagnostics);
        diagnostics.Record("launch", "Launch requested.");

        var startupOptions = BurrowStartupOptions.FromLaunchArguments(args.Arguments);
        diagnostics.Record(
            "launch",
            $"Options showTrayHud={startupOptions.ShowTrayHudDiagnostic}; disableTray={startupOptions.DisableTray}; route={startupOptions.InitialRoute ?? "<default>"}.");

        try
        {
            _window = _host.Services.GetRequiredService<MainWindow>();
        }
        catch (Exception ex)
        {
            diagnostics.RecordException("window", ex);
            throw;
        }

        var settingsService = _host.Services.GetRequiredService<IApplicationSettingsService>();
        var trayIconService = _host.Services.GetRequiredService<ITrayIconService>();

        settingsService.SettingsChanged += (_, settings) =>
        {
            var window = _window;
            if (window is null)
            {
                return;
            }

            window.DispatcherQueue.TryEnqueue(() =>
            {
                if (settings.TrayIconEnabled && !startupOptions.DisableTray)
                {
                    InitializeTraySafely(window, trayIconService, diagnostics);
                }
                else
                {
                    DisposeTraySafely(trayIconService, diagnostics);
                }
            });
        };

        _window.Closed += (_, _) =>
        {
            diagnostics.Record("window", "Main window closed.");
            DisposeTraySafely(trayIconService, diagnostics);
            StopHostInBackground(diagnostics);
        };

        _window.Activate();
        diagnostics.Record("window", "Main window activated.");
        StartHostInBackground(diagnostics);

        _window.DispatcherQueue.TryEnqueue(() =>
        {
            if (ShouldInitializeTray(settingsService.Current, startupOptions))
            {
                InitializeTraySafely(_window, trayIconService, diagnostics);
            }

            if (startupOptions.ShowTrayHudDiagnostic)
            {
                _ = ShowTrayHudForDiagnosticsAsync(_window, trayIconService, diagnostics);
            }

            if (!string.IsNullOrWhiteSpace(startupOptions.InitialRoute))
            {
                _ = NavigateForDiagnosticsAsync(_window, startupOptions.InitialRoute, diagnostics);
            }
        });
    }

    private void RegisterExceptionLogging(IStartupDiagnosticsService diagnostics)
    {
        if (_exceptionLoggingRegistered)
        {
            return;
        }

        _exceptionLoggingRegistered = true;
        UnhandledException += (_, eventArgs) =>
        {
            diagnostics.RecordException("xaml_unhandled", eventArgs.Exception);
        };
        AppDomain.CurrentDomain.UnhandledException += (_, eventArgs) =>
        {
            if (eventArgs.ExceptionObject is Exception exception)
            {
                diagnostics.RecordException("domain_unhandled", exception);
            }
            else
            {
                diagnostics.Record("domain_unhandled", eventArgs.ExceptionObject?.ToString() ?? "Unknown exception.");
            }
        };
        TaskScheduler.UnobservedTaskException += (_, eventArgs) =>
        {
            diagnostics.RecordException("task_unobserved", eventArgs.Exception);
            eventArgs.SetObserved();
        };
    }

    private void StartHostInBackground(IStartupDiagnosticsService diagnostics)
    {
        if (_hostStartRequested)
        {
            return;
        }

        _hostStartRequested = true;
        _ = Task.Run(async () =>
        {
            try
            {
                diagnostics.Record("host", "Starting hosted services.");
                await _host.StartAsync().ConfigureAwait(false);
                diagnostics.Record("host", "Hosted services started.");
            }
            catch (Exception ex)
            {
                diagnostics.RecordException("host", ex);
            }
        });
    }

    private void StopHostInBackground(IStartupDiagnosticsService diagnostics)
    {
        _ = Task.Run(async () =>
        {
            try
            {
                diagnostics.Record("host", "Stopping hosted services.");
                await _host.StopAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
                diagnostics.Record("host", "Hosted services stopped.");
            }
            catch (Exception ex)
            {
                diagnostics.RecordException("host", ex);
            }
            finally
            {
                _host.Dispose();
            }
        });
    }

    private static bool ShouldInitializeTray(BurrowSettings settings, BurrowStartupOptions startupOptions)
    {
        return (settings.TrayIconEnabled && !startupOptions.DisableTray) || startupOptions.ShowTrayHudDiagnostic;
    }

    private static void InitializeTraySafely(
        Window window,
        ITrayIconService trayIconService,
        IStartupDiagnosticsService diagnostics)
    {
        try
        {
            trayIconService.Initialize(window);
            diagnostics.Record("tray", "Tray service initialized.");
        }
        catch (Exception ex)
        {
            diagnostics.RecordException("tray", ex);
        }
    }

    private static void DisposeTraySafely(
        ITrayIconService trayIconService,
        IStartupDiagnosticsService diagnostics)
    {
        try
        {
            trayIconService.Dispose();
            diagnostics.Record("tray", "Tray service disposed.");
        }
        catch (Exception ex)
        {
            diagnostics.RecordException("tray", ex);
        }
    }

    private static async Task ShowTrayHudForDiagnosticsAsync(
        Window window,
        ITrayIconService trayIconService,
        IStartupDiagnosticsService diagnostics)
    {
        await Task.Delay(TimeSpan.FromSeconds(2)).ConfigureAwait(false);
        if (!window.DispatcherQueue.TryEnqueue(() =>
            {
                diagnostics.Record("tray_hud", "Opening tray HUD diagnostic window.");
                trayIconService.ShowHudForDiagnostics(640, 720);
            }))
        {
            diagnostics.Record("tray_hud", "Failed to enqueue tray HUD diagnostic window.");
        }
    }

    private static async Task NavigateForDiagnosticsAsync(
        Window window,
        string route,
        IStartupDiagnosticsService diagnostics)
    {
        await Task.Delay(TimeSpan.FromMilliseconds(500)).ConfigureAwait(false);
        if (!window.DispatcherQueue.TryEnqueue(() =>
            {
                diagnostics.Record("navigation", $"Opening startup route: {route}");
                GetService<ShellViewModel>().NavigateCommand.Execute(route);
            }))
        {
            diagnostics.Record("navigation", $"Failed to enqueue startup route: {route}");
        }
    }
}
