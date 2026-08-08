{******************************************************************************

  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain
  one at https://mozilla.org/MPL/2.0/.

*******************************************************************************}

program BSArchPro;

{$I baDefines.inc}

uses
  CMem,
  Interfaces, // this includes the LCL widgetset
  Forms,
  System.IOUtils,
  SysUtils,
  wbBSArchive in 'Core\wbBSArchive.pas',
  wbCompression in 'Core\wbCompression.pas',
  wbDDS in 'Core\wbDDS.pas',
  wbHash in 'Core\wbHash.pas',
  wbStreams in 'Core\wbStreams.pas',
  wbTaskProgress in 'Core\wbTaskProgress.pas' {FormTaskProgress},
  frmArchiveInfo in 'BSArch\frmArchiveInfo.pas' {FormArchiveInfo},
  frmMain in 'BSArch\frmMain.pas' {FormMain},
  frmPack in 'BSArch\frmPack.pas' {FormPack},
  frmSearchReplace in 'BSArch\frmSearchReplace.pas' {FormSearchReplace};

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.ShowHint := True;
  Application.HintPause := 200;
  Application.HintHidePause := 10000;
  Application.Title := 'BSArchPro';
  Application.CreateForm(TFormMain, FormMain);
  Application.Run;
end.
