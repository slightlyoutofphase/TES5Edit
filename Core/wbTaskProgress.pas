{******************************************************************************
  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain
  one at https://mozilla.org/MPL/2.0/.
*******************************************************************************}
unit wbTaskProgress;

{$mode Delphi}
{$modeswitch inlinevars}

interface

uses
  Classes,
  SyncObjs,
  SysUtils,
  LMessages,
  ComCtrls,
  Controls,
  ExtCtrls,
  Forms,
  StdCtrls,
  LightweightMREW;

const
  LM_PROGRESS_UPDATE = LM_USER;
  LM_PROGRESS_ERROR  = LM_USER + 1;

type
  TProc<T> = reference to procedure(Arg1: T);

  TwbTaskWorkerThread = class;

  TProcessProc = TProc<Integer>;

  TProgressBarWithText = class(TProgressBar)
  private
    FProgressText: string;
    FProgressTextMult: Double;
  protected
    procedure WMPaint(var Msg: TLMPaint); message LM_PAINT;
  public
    property ProgressText: string read FProgressText write FProgressText;
    property ProgressTextMult: Double read FProgressTextMult write FProgressTextMult;
  end;

  TFormTaskProgress = class(TForm)
    ProgressBar: TProgressBar;
    btnCancel: TButton;
    pnlError: TPanel;
    Label1: TLabel;
    memoError: TMemo;
    procedure FormActivate(Sender: TObject);
    procedure btnCancelClick(Sender: TObject);
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure FormCreate(Sender: TObject);
  private
    { Private declarations }
    fLowIndex: Integer;
    fHighIndex: Integer;
    fCurrentIndex: Integer;
    fProgressTextMult: Double;

    {$IF 1} { Delphi 10.4 / LightweightMREW compatibility unit }
    fObjectLock: TLightweightMREW;
    {$ELSE}
    fObjectLock: IReadWriteSync;
    {$IFEND}

    fProcessProc: TProcessProc;
    fThreadPool: array of TwbTaskWorkerThread;
    fThreads: Integer;
    fCancelled: Boolean;
    fCancelCloses: Boolean;
    fExceptionIndex: Integer;
    fExceptionMessage: string;
    fHeight: Integer;
    fRunning: Boolean;

    procedure StartProcessing;
    procedure WMProgressUpdate(var msg: TLMessage); message LM_PROGRESS_UPDATE;
    procedure WMProgressError(var msg: TLMessage); message LM_PROGRESS_ERROR;
  protected
    // processing function called by worker threads, returns False when no jobs left
    function ProcessNext: Boolean;
  public
    { Public declarations }
    TaskResult: TModalResult;
  end;

  TwbWorkerObjectProc = function: Boolean of object;

  TwbTaskWorkerThread = class(TThread)
  private
    fObjectProc: TwbWorkerObjectProc;
  protected
    procedure Execute; override;
  public
    constructor Create(aObjectProc: TwbWorkerObjectProc);
  end;

  TwbTaskProgress = class
  public
    Owner: TComponent;
    Threads: Integer;
    ProcessProc: TProcessProc;
    Caption: string;
    ProgressTextMult: Double;
    LowIndex: Integer;
    HighIndex: Integer;
    ErrorIndex: Integer;
    ErrorMessage: string;

    constructor Create(aOwner: TComponent);
    function Execute: TModalResult;
  end;

implementation

{$R *.lfm}

uses
  {$IFDEF MSWINDOWS}
  ComObj,
  ShlObj,
  Windows,
  {$ENDIF}
  LCLIntf,
  LCLType;

{$IFDEF MSWINDOWS}
var
  TaskbarList: ITaskbarList;
  TaskbarList2: ITaskbarList2;
  TaskbarList3: ITaskbarList3;
  TaskbarList4: ITaskbarList4;
{$ENDIF}

//============================================================================
procedure TProgressBarWithText.WMPaint(var Msg: TLMPaint);
var
  DC: HDC;
  prevfont: HGDIOBJ;
  prevbkmode: Integer;
  R: TRect;
  s: string;
begin
  inherited;

  {$IFDEF MSWINDOWS}
  s := ProgressText;
  if s = '' then
    s := Format('%d/%d', [Round(Position * FProgressTextMult), Round(Max * FProgressTextMult)]);

  R := ClientRect;
  DC := GetWindowDC(Handle);
  try
    prevbkmode := SetBkMode(DC, TRANSPARENT);
    prevfont := SelectObject(DC, Font.Handle);
    DrawText(DC, PChar(s), Length(s), R, DT_SINGLELINE or DT_CENTER or DT_VCENTER);
    SelectObject(DC, prevfont);
    SetBkMode(DC, prevbkmode);
  finally
    ReleaseDC(Handle, DC);
  end;
  {$ELSE}
  // Non-Windows: just let the normal LCL progress bar paint.
  // (You can later overlay a TLabel if you want text on Linux/macOS.)
  {$ENDIF}
end;

//============================================================================
function CalcThreads(aCores: Integer): Integer;
begin
  // leave one core for the system, we are generous :)
  Result := aCores - 1;
  // multithreading means 2 threads at least
  if Result < 2 then
    Result := 2;
end;

//============================================================================
constructor TwbTaskProgress.Create(aOwner: TComponent);
begin
  Owner := aOwner;
  ProgressTextMult := 1;
end;

//============================================================================
function TwbTaskProgress.Execute: TModalResult;
begin
  Result := mrCancel;
  var Count := HighIndex - LowIndex + 1;
  if Count <= 0 then
    Exit;

  with TFormTaskProgress.Create(Owner) do
  try
    Caption := Self.Caption;
    fLowIndex := Self.LowIndex;
    fHighIndex := Self.HighIndex;
    fProcessProc := Self.ProcessProc;
    fThreads := Self.Threads;
    fProgressTextMult := Self.ProgressTextMult;

    if fThreads = 0 then
    begin
      fThreads := CalcThreads(System.CPUCount);
      if fThreads <= 0 then
        fThreads := 1;
    end;
    if fThreads > Count then
      fThreads := Count;

    ShowModal;
    Result := TaskResult;
    Self.ErrorIndex := fExceptionIndex;
    Self.ErrorMessage := fExceptionMessage;
  finally
    Free;
  end;
end;

{$IFDEF MSWINDOWS}
const
  SID_ITaskbarList  = '{56FDF342-FD6D-11D0-958A-006097C9A090}';
  SID_ITaskbarList2 = '{602D4995-B13A-429B-A66E-1935E44F4317}';
  SID_ITaskbarList3 = '{EA1AFB91-9E28-4B86-90E9-9E9F8A5EEFAF}';
  SID_ITaskbarList4 = '{C43DC798-95D1-4BEA-9030-BB99E2983A1A}';

const
  IID_ITaskbarList:  TGUID = SID_ITaskbarList;
  IID_ITaskbarList2: TGUID = SID_ITaskbarList2;
  IID_ITaskbarList3: TGUID = SID_ITaskbarList3;
  IID_ITaskbarList4: TGUID = SID_ITaskbarList4;
  CLSID_TaskbarList: TGUID = '{56FDF344-FD6D-11D0-958A-006097C9A090}';
{$ENDIF}

//============================================================================
procedure InitializeTaskbars;
begin
  {$IFDEF MSWINDOWS}
  if Win32MajorVersion < 6 then
    Exit;
  if Assigned(TaskbarList) then
    Exit;

  try
    TaskbarList := CreateComObject(CLSID_TaskbarList) as ITaskbarList;
  except
    Exit;
  end;

  TaskbarList.HrInit;
  Supports(TaskbarList, IID_ITaskbarList2, TaskbarList2);
  Supports(TaskbarList, IID_ITaskbarList3, TaskbarList3);
  Supports(TaskbarList, IID_ITaskbarList4, TaskbarList4);
  {$ENDIF}
end;

//============================================================================
procedure TaskbarShowProgress(Handle: THandle; ProgressPos, ProgressMax: Integer);
begin
  {$IFDEF MSWINDOWS}
  if not Assigned(TaskbarList3) then
    Exit;
  TaskbarList3.SetProgressState(Handle, TBPF_NORMAL);
  TaskbarList3.SetProgressValue(Handle, ProgressPos, ProgressMax);
  {$ENDIF}
end;

//============================================================================
procedure TaskbarErrorProgress(Handle: THandle);
begin
  {$IFDEF MSWINDOWS}
  if not Assigned(TaskbarList3) then
    Exit;
  TaskbarList3.SetProgressState(Handle, TBPF_ERROR);
  {$ENDIF}
end;

//============================================================================
procedure TaskbarHideProgress(Handle: THandle);
begin
  {$IFDEF MSWINDOWS}
  if not Assigned(TaskbarList3) then
    Exit;
  TaskbarList3.SetProgressState(Handle, TBPF_NOPROGRESS);
  {$ENDIF}
end;

//============================================================================
constructor TwbTaskWorkerThread.Create(aObjectProc: TwbWorkerObjectProc);
begin
  fObjectProc := aObjectProc;
  FreeOnTerminate := False;
  inherited Create(False);
end;

//============================================================================
procedure TwbTaskWorkerThread.Execute;
begin
  while not Terminated do
    if not fObjectProc then
      Break;
end;

//============================================================================
function TFormTaskProgress.ProcessNext: Boolean;
var
  CurIndex: Integer;
begin
  fObjectLock.BeginWrite;
  try
    if (fCurrentIndex > fHighIndex) or (fExceptionIndex <> -1) then
      CurIndex := -1
    else
    begin
      CurIndex := fCurrentIndex;
      Inc(fCurrentIndex);
    end;
  finally
    fObjectLock.EndWrite;
  end;

  Result := False;
  if CurIndex = -1 then
    Exit;

  PostMessage(Handle, LM_PROGRESS_UPDATE, CurIndex, 0);

  try
    fProcessProc(CurIndex);
    Result := True;
  except
    on E: Exception do
    begin
      fObjectLock.BeginWrite;
      try
        // only the first exception wins
        if fExceptionIndex = -1 then
        begin
          fExceptionIndex := CurIndex;
          fExceptionMessage := E.Message;
        end;
      finally
        fObjectLock.EndWrite;
      end;
    end;
  end;
end;

//============================================================================
procedure TFormTaskProgress.StartProcessing;
  // returns the number of finished threads
  function GetFinishedThreads: Integer;
  begin
    Result := 0;
    for var t in fThreadPool do
      if t.Finished then
        Inc(Result);
  end;

begin
  fRunning := True;

  // give time for the form to draw itself
  Sleep(100);

  {$IF 0}
  fObjectLock := TReadWriteSync.Create;
  {$IFEND}

  fCurrentIndex := fLowIndex;
  fExceptionIndex := -1;

  SetLength(fThreadPool, fThreads);

  // create and start worker threads
  for var i := Low(fThreadPool) to High(fThreadPool) do
    fThreadPool[i] := TwbTaskWorkerThread.Create(ProcessNext);

  // poll threads until all have finished
  while GetFinishedThreads <> Length(fThreadPool) do
  begin
    // stop all threads if Cancel was pressed or exception occurred
    if fCancelled or (fExceptionIndex <> -1) then
      for var t in fThreadPool do
        if not t.Finished and not t.Terminated then
          t.Terminate;

    Sleep(200);
  end;

  // clear threads, all have finished by now
  for var t in fThreadPool do
    t.Free;
  SetLength(fThreadPool, 0);

  fRunning := False;

  if fExceptionIndex <> -1 then
  begin
    TaskResult := mrAbort;
    PostMessage(Handle, LM_PROGRESS_ERROR, 0, 0);
    // do not close window if error has occurred, Cancel button will close
    fCancelCloses := True;
  end
  else
  begin
    if fCancelled then
      TaskResult := mrCancel
    else
      TaskResult := mrOk;

    // close window
    PostMessage(Handle, WM_CLOSE, 0, 0);
  end;
end;

//============================================================================
procedure TFormTaskProgress.WMProgressUpdate(var msg: TLMessage);
begin
  ProgressBar.Position := msg.WParam;
  {$IFDEF MSWINDOWS}
  TaskbarShowProgress(Application.MainFormHandle, ProgressBar.Position, ProgressBar.Max);
  {$ENDIF}
end;

//============================================================================
procedure TFormTaskProgress.WMProgressError(var msg: TLMessage);
begin
  ProgressBar.Position := fExceptionIndex;
  {$IFDEF MSWINDOWS}
  TaskbarErrorProgress(Application.MainFormHandle);
  {$ENDIF}
  Height := fHeight;
  pnlError.Visible := True;
  memoError.Lines.Text := fExceptionMessage;
end;

//============================================================================
procedure TFormTaskProgress.btnCancelClick(Sender: TObject);
begin
  // since window autocloses when everything is ok, there are only
  // 2 possibilities when Cancel can be pressed: while running or after error
  if fRunning then
    fCancelled := True
  else if fCancelCloses then
    Close;
end;

//============================================================================
procedure TFormTaskProgress.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  // closing with X while running is the same as pressing Cancel
  if fRunning then
  begin
    btnCancel.Click;
    Action := caNone;
    Exit;
  end;

  {$IFDEF MSWINDOWS}
  TaskbarHideProgress(Application.MainFormHandle);
  {$ENDIF}
end;

//============================================================================
procedure TFormTaskProgress.FormCreate(Sender: TObject);
var
  pg: TProgressBarWithText;
begin
  Font.Size := Screen.MenuFont.Size;

  fHeight := Height;
  Height := Height - pnlError.Top + 2;

  // replace the designer progress bar with our text-capable version
  pg := TProgressBarWithText.Create(Self);
  pg.Parent := ProgressBar.Parent;
  pg.Left := ProgressBar.Left;
  pg.Top := ProgressBar.Top;
  pg.Width := ProgressBar.Width;
  pg.Height := ProgressBar.Height;
  pg.Smooth := ProgressBar.Smooth;
  pg.Anchors := ProgressBar.Anchors;

  ProgressBar.Free;
  ProgressBar := pg;
end;

//============================================================================
procedure TFormTaskProgress.FormActivate(Sender: TObject);
begin
  InitializeTaskbars;

  ProgressBar.Min := fLowIndex;
  ProgressBar.Max := fHighIndex;

  if ProgressBar is TProgressBarWithText then
    TProgressBarWithText(ProgressBar).ProgressTextMult := fProgressTextMult;

  // start the real work on a background thread so the form can paint
  TThread.CreateAnonymousThread(StartProcessing).Start;
end;

end.
