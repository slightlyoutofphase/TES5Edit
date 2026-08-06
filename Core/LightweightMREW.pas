{
  TLightweightMREW for Free Pascal (trunk)

  Delphi-compatible reader/writer lock record matching
  System.SyncObjs.TLightweightMREW (RAD Studio 10.4.1+).

  Platforms:
    - Windows : Slim Reader/Writer (SRW) locks (kernel32)
    - Unix    : pthread_rwlock (packages/pthreads)
    - other   : TRTLCriticalSection fallback (readers serialize)

  Notes (same as Delphi):
    - Intended as an embedded field, not a heap object.
    - Do not copy/move while locked. Prefer a single field lifetime.
    - Read locks are reentrant on typical OS implementations; write locks are not.
    - Not upgradeable (holding a read lock then BeginWrite can deadlock).
    - Not write-biased (writer starvation is possible under continuous readers).

  Requires FPC with advanced records / management operators (trunk / 3.3.x).
}

unit LightweightMREW;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

{$IFDEF MSWINDOWS}
  {$DEFINE HAS_SRWLOCK}
{$ENDIF}
{$IFDEF UNIX}
  {$DEFINE HAS_PTHREAD_RWLOCK}
{$ENDIF}

interface

uses
  SysUtils
{$IFDEF HAS_PTHREAD_RWLOCK}
  , unixtype
{$ENDIF}
  ;

type
  { Lightweight multi-read, exclusive-write lock (record). }
  TLightweightMREW = record
  private
{$IFDEF HAS_SRWLOCK}
    { SRWLOCK is pointer-sized }
    FNativeRW: Pointer;
{$ELSE}
  {$IFDEF HAS_PTHREAD_RWLOCK}
    FNativeRW: pthread_rwlock_t;
  {$ELSE}
    FLock: TRTLCriticalSection;
  {$ENDIF}
{$ENDIF}
  public
    class operator Initialize(var Dest: TLightweightMREW);
    class operator Finalize(var Dest: TLightweightMREW);

    procedure BeginRead;
    function  TryBeginRead: Boolean;
{$IFDEF HAS_PTHREAD_RWLOCK}
    function  TryBeginRead(Timeout: Cardinal): Boolean; overload;
{$ENDIF}
    procedure EndRead;

    procedure BeginWrite;
    function  TryBeginWrite: Boolean;
{$IFDEF HAS_PTHREAD_RWLOCK}
    function  TryBeginWrite(Timeout: Cardinal): Boolean; overload;
{$ENDIF}
    procedure EndWrite;
  end;

implementation

{$IFDEF HAS_SRWLOCK}
uses
  Windows;
{$ENDIF}

{$IFDEF HAS_PTHREAD_RWLOCK}
uses
  BaseUnix, pthreads
{$IFDEF LINUX}
  , Unix
{$ENDIF}
  ;
{$ENDIF}

{$IFDEF HAS_SRWLOCK}
{------------------------------------------------------------------------------
  Windows SRW lock API (not yet declared in FPC Windows unit as of trunk)
 ------------------------------------------------------------------------------}
type
  PSRWLOCK = ^TSRWLOCK;
  TSRWLOCK = record
    Ptr: Pointer;
  end;

procedure InitializeSRWLock(out SRWLock: TSRWLOCK); stdcall;
  external 'kernel32.dll' name 'InitializeSRWLock';
procedure AcquireSRWLockShared(var SRWLock: TSRWLOCK); stdcall;
  external 'kernel32.dll' name 'AcquireSRWLockShared';
procedure ReleaseSRWLockShared(var SRWLock: TSRWLOCK); stdcall;
  external 'kernel32.dll' name 'ReleaseSRWLockShared';
procedure AcquireSRWLockExclusive(var SRWLock: TSRWLOCK); stdcall;
  external 'kernel32.dll' name 'AcquireSRWLockExclusive';
procedure ReleaseSRWLockExclusive(var SRWLock: TSRWLOCK); stdcall;
  external 'kernel32.dll' name 'ReleaseSRWLockExclusive';
function  TryAcquireSRWLockShared(var SRWLock: TSRWLOCK): BOOL; stdcall;
  external 'kernel32.dll' name 'TryAcquireSRWLockShared';
function  TryAcquireSRWLockExclusive(var SRWLock: TSRWLOCK): BOOL; stdcall;
  external 'kernel32.dll' name 'TryAcquireSRWLockExclusive';
{$ENDIF HAS_SRWLOCK}

{$IFDEF HAS_PTHREAD_RWLOCK}
procedure MSecsFromNowLocal(const tNow: TTimeVal; aTimeout: Integer; out tFuture: TTimeSpec);
var
  td, tm: Integer;
  nsec: Int64;
begin
  td := aTimeout div 1000;
  tm := aTimeout mod 1000;
  tFuture.tv_sec := tNow.tv_sec + td;
  nsec := Int64(tNow.tv_usec) * 1000 + Int64(tm) * 1000000;
  tFuture.tv_sec := tFuture.tv_sec + nsec div 1000000000;
  tFuture.tv_nsec := LongInt(nsec mod 1000000000);
end;
{$ENDIF HAS_PTHREAD_RWLOCK}

{ TLightweightMREW }

class operator TLightweightMREW.Initialize(var Dest: TLightweightMREW);
begin
{$IFDEF HAS_SRWLOCK}
  InitializeSRWLock(TSRWLOCK(Dest.FNativeRW));
{$ELSE}
  {$IFDEF HAS_PTHREAD_RWLOCK}
  CheckOSError(pthread_rwlock_init(@Dest.FNativeRW, nil));
  {$ELSE}
  InitCriticalSection(Dest.FLock);
  {$ENDIF}
{$ENDIF}
end;

class operator TLightweightMREW.Finalize(var Dest: TLightweightMREW);
begin
{$IFDEF HAS_SRWLOCK}
  { SRWLOCK has no destroy }
  Dest.FNativeRW := nil;
{$ELSE}
  {$IFDEF HAS_PTHREAD_RWLOCK}
  { Destroy only if no waiters/owners; undefined if still locked }
  pthread_rwlock_destroy(@Dest.FNativeRW);
  {$ELSE}
  DoneCriticalSection(Dest.FLock);
  {$ENDIF}
{$ENDIF}
end;

procedure TLightweightMREW.BeginRead;
begin
{$IFDEF HAS_SRWLOCK}
  AcquireSRWLockShared(TSRWLOCK(FNativeRW));
{$ELSE}
  {$IFDEF HAS_PTHREAD_RWLOCK}
  CheckOSError(pthread_rwlock_rdlock(@FNativeRW));
  {$ELSE}
  EnterCriticalSection(FLock);
  {$ENDIF}
{$ENDIF}
end;

function TLightweightMREW.TryBeginRead: Boolean;
{$IFDEF HAS_PTHREAD_RWLOCK}
var
  err: cint;
{$ENDIF}
begin
{$IFDEF HAS_SRWLOCK}
  Result := TryAcquireSRWLockShared(TSRWLOCK(FNativeRW));
{$ELSE}
  {$IFDEF HAS_PTHREAD_RWLOCK}
  err := pthread_rwlock_tryrdlock(@FNativeRW);
  if err = 0 then
    Result := True
  else if (err = ESysEBUSY) or (err = ESysEAGAIN) then
    Result := False
  else
    begin
      CheckOSError(err);
      Result := False;
    end;
  {$ELSE}
  Result := TryEnterCriticalSection(FLock) <> 0;
  {$ENDIF}
{$ENDIF}
end;

{$IFDEF HAS_PTHREAD_RWLOCK}
function TLightweightMREW.TryBeginRead(Timeout: Cardinal): Boolean;
var
  err: cint;
  tnow: TTimeVal;
  ts: TTimeSpec;
begin
  if Timeout = 0 then
    Exit(TryBeginRead);

  if Timeout = Cardinal(-1) then { INFINITE }
  begin
    BeginRead;
    Exit(True);
  end;

  fpgettimeofday(@tnow, nil);
  MSecsFromNowLocal(tnow, Integer(Timeout), ts);
  err := pthread_rwlock_timedrdlock(@FNativeRW, @ts);
  if err = 0 then
    Result := True
  else if (err = ESysETIMEDOUT) or (err = ESysEBUSY) or (err = ESysEAGAIN) then
    Result := False
  else
    begin
      CheckOSError(err);
      Result := False;
    end;
end;
{$ENDIF HAS_PTHREAD_RWLOCK}

procedure TLightweightMREW.EndRead;
begin
{$IFDEF HAS_SRWLOCK}
  ReleaseSRWLockShared(TSRWLOCK(FNativeRW));
{$ELSE}
  {$IFDEF HAS_PTHREAD_RWLOCK}
  CheckOSError(pthread_rwlock_unlock(@FNativeRW));
  {$ELSE}
  LeaveCriticalSection(FLock);
  {$ENDIF}
{$ENDIF}
end;

procedure TLightweightMREW.BeginWrite;
begin
{$IFDEF HAS_SRWLOCK}
  AcquireSRWLockExclusive(TSRWLOCK(FNativeRW));
{$ELSE}
  {$IFDEF HAS_PTHREAD_RWLOCK}
  CheckOSError(pthread_rwlock_wrlock(@FNativeRW));
  {$ELSE}
  EnterCriticalSection(FLock);
  {$ENDIF}
{$ENDIF}
end;

function TLightweightMREW.TryBeginWrite: Boolean;
{$IFDEF HAS_PTHREAD_RWLOCK}
var
  err: cint;
{$ENDIF}
begin
{$IFDEF HAS_SRWLOCK}
  Result := TryAcquireSRWLockExclusive(TSRWLOCK(FNativeRW));
{$ELSE}
  {$IFDEF HAS_PTHREAD_RWLOCK}
  err := pthread_rwlock_trywrlock(@FNativeRW);
  if err = 0 then
    Result := True
  else if (err = ESysEBUSY) or (err = ESysEAGAIN) then
    Result := False
  else
    begin
      CheckOSError(err);
      Result := False;
    end;
  {$ELSE}
  Result := TryEnterCriticalSection(FLock) <> 0;
  {$ENDIF}
{$ENDIF}
end;

{$IFDEF HAS_PTHREAD_RWLOCK}
function TLightweightMREW.TryBeginWrite(Timeout: Cardinal): Boolean;
var
  err: cint;
  tnow: TTimeVal;
  ts: TTimeSpec;
begin
  if Timeout = 0 then
    Exit(TryBeginWrite);

  if Timeout = Cardinal(-1) then
  begin
    BeginWrite;
    Exit(True);
  end;

  fpgettimeofday(@tnow, nil);
  MSecsFromNowLocal(tnow, Integer(Timeout), ts);
  err := pthread_rwlock_timedwrlock(@FNativeRW, @ts);
  if err = 0 then
    Result := True
  else if (err = ESysETIMEDOUT) or (err = ESysEBUSY) or (err = ESysEAGAIN) then
    Result := False
  else
    begin
      CheckOSError(err);
      Result := False;
    end;
end;
{$ENDIF HAS_PTHREAD_RWLOCK}

procedure TLightweightMREW.EndWrite;
begin
{$IFDEF HAS_SRWLOCK}
  ReleaseSRWLockExclusive(TSRWLOCK(FNativeRW));
{$ELSE}
  {$IFDEF HAS_PTHREAD_RWLOCK}
  CheckOSError(pthread_rwlock_unlock(@FNativeRW));
  {$ELSE}
  LeaveCriticalSection(FLock);
  {$ENDIF}
{$ENDIF}
end;

end.