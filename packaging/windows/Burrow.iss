#define AppPublisher "Caezium"
#define AppName "Burrow"
#define AppExeName "BurrowWin.exe"

#ifndef AppVersion
  #error AppVersion must be defined by the release script.
#endif

#ifndef SourceDir
  #error SourceDir must be defined by the release script.
#endif

#ifndef OutputDir
  #error OutputDir must be defined by the release script.
#endif

#ifndef OutputBaseFilename
  #error OutputBaseFilename must be defined by the release script.
#endif

#ifndef AppIcon
  #error AppIcon must be defined by the release script.
#endif

[Setup]
AppId={{62F8F319-AF77-4B08-9A69-F60C7AC74C22}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL=https://github.com/caezium/Burrow
AppSupportURL=https://github.com/caezium/Burrow/issues
AppUpdatesURL=https://github.com/caezium/Burrow/releases
DefaultDirName={localappdata}\Programs\Burrow
DefaultGroupName=Burrow
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseFilename}
SetupIconFile={#AppIcon}
UninstallDisplayIcon={app}\{#AppExeName}
UninstallDisplayName=Burrow
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes
RestartApplications=no
MinVersion=10.0.17763

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Burrow"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\Assets\AppIcon.ico"

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Launch Burrow"; Flags: nowait postinstall skipifsilent
