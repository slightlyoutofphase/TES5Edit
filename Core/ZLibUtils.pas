{******************************************************************************}
{  ZLibUtils.pas - FPC-compatible ZCompressStream (and helpers)                 }
{                                                                              }
{  Compatible with Delphi System.ZLib.ZCompressStream API.                     }
{  Uses the Free Pascal packages/zlib bindings (libz / zlib1).                 }
{                                                                              }
{  Usage:                                                                      }
{    uses Classes, SysUtils, ZLibUtils;                                        }
{                                                                              }
{    ZCompressStream(InStream, OutStream);           // default level          }
{    ZCompressStream(InStream, OutStream, zcMax);    // or explicit level      }
{******************************************************************************}

unit ZLibUtils;

{$mode objfpc}{$H+}
{$IFDEF WINDOWS}
  { Make sure zlib1.dll (or equivalent) is available / linked }
{$ENDIF}

interface

uses
  SysUtils, Classes,
  zlib;   { FPC packages/zlib - https://gitlab.com/freepascal.org/fpc/source/-/tree/main/packages/zlib }

type
  { Compression levels - identical to Delphi System.ZLib.TZCompressionLevel }
  TZCompressionLevel = (
    zcNone,      { Z_NO_COMPRESSION       =  0 }
    zcFastest,   { Z_BEST_SPEED           =  1 }
    zcDefault,   { Z_DEFAULT_COMPRESSION  = -1 }
    zcMax        { Z_BEST_COMPRESSION     =  9 }
  );

  { Exception hierarchy matching Delphi }
  EZLibError = class(Exception);
  EZCompressionError = class(EZLibError);
  EZDecompressionError = class(EZLibError);  { included for completeness }

{******************************************************************************}
{ ZCompressStream                                                              }
{                                                                              }
{ Compresses the entire contents of inStream into outStream using zlib.        }
{ level defaults to zcDefault when omitted.                                    }
{                                                                              }
{ May raise EZCompressionError with one of the classic zlib messages:          }
{   'file error', 'stream error', 'data error', 'insufficient memory',         }
{   'buffer error', 'incompatible version'                                     }
{******************************************************************************}
procedure ZCompressStream(inStream, outStream: TStream;
  level: TZCompressionLevel = zcDefault);

{ Optional convenience overload / helper (not required by the original API) }
procedure ZCompressStream(inStream, outStream: TStream; level: Integer); overload;

implementation

const
  { Map TZCompressionLevel -> zlib integer constants }
  Levels: array[TZCompressionLevel] of Integer = (
    Z_NO_COMPRESSION,       { zcNone    }
    Z_BEST_SPEED,           { zcFastest }
    Z_DEFAULT_COMPRESSION,  { zcDefault }
    Z_BEST_COMPRESSION      { zcMax     }
  );

  { Classic zlib error messages (index = 2 - code for negative codes) }
  _z_errmsg: array[0..9] of string = (
    'need dictionary',      { Z_NEED_DICT       =  2 }
    'stream end',           { Z_STREAM_END      =  1 }
    '',                     { Z_OK              =  0 }
    'file error',           { Z_ERRNO           = -1 }
    'stream error',         { Z_STREAM_ERROR    = -2 }
    'data error',           { Z_DATA_ERROR      = -3 }
    'insufficient memory',  { Z_MEM_ERROR       = -4 }
    'buffer error',         { Z_BUF_ERROR       = -5 }
    'incompatible version', { Z_VERSION_ERROR   = -6 }
    ''
  );

const
  BufferSize = 32768;  { 32 KiB - good balance of performance / stack usage }

{------------------------------------------------------------------------------}
function ZCompressCheck(code: Integer): Integer;
begin
  Result := code;
  if code < 0 then
  begin
    { Translate zlib code into the classic message }
    if (code >= Z_VERSION_ERROR) and (code <= Z_NEED_DICT) then
      raise EZCompressionError.Create(_z_errmsg[2 - code])
    else
      raise EZCompressionError.CreateFmt('ZLib compression error %d', [code]);
  end;
end;

{------------------------------------------------------------------------------}
procedure ZInternalCompressStream(var zstream: TZStream;
  inStream, outStream: TStream);
var
  zresult: Integer;
  inBuffer: array[0..BufferSize - 1] of Byte;
  outBuffer: array[0..BufferSize - 1] of Byte;
  outSize: Integer;
begin
  zresult := Z_STREAM_END;  { sentinel }

  { Prime the first input chunk }
  zstream.avail_in := inStream.Read(inBuffer, BufferSize);

  while zstream.avail_in > 0 do
  begin
    zstream.next_in := @inBuffer[0];

    repeat
      zstream.next_out := @outBuffer[0];
      zstream.avail_out := BufferSize;

      zresult := ZCompressCheck(deflate(zstream, Z_NO_FLUSH));

      outSize := BufferSize - Integer(zstream.avail_out);
      if outSize > 0 then
        outStream.WriteBuffer(outBuffer, outSize);
    until (zresult = Z_STREAM_END) or (zstream.avail_in = 0);

    { Next input chunk }
    zstream.avail_in := inStream.Read(inBuffer, BufferSize);
  end;

  { Finish the stream (flush remaining compressed data) }
  while zresult <> Z_STREAM_END do
  begin
    zstream.next_out := @outBuffer[0];
    zstream.avail_out := BufferSize;

    zresult := ZCompressCheck(deflate(zstream, Z_FINISH));

    outSize := BufferSize - Integer(zstream.avail_out);
    if outSize > 0 then
      outStream.WriteBuffer(outBuffer, outSize);
  end;

  ZCompressCheck(deflateEnd(zstream));
end;

{------------------------------------------------------------------------------}
procedure ZCompressStream(inStream, outStream: TStream;
  level: TZCompressionLevel);
var
  zstream: TZStream;
begin
  if (inStream = nil) or (outStream = nil) then
    raise EZCompressionError.Create('stream error');

  FillChar(zstream, SizeOf(zstream), 0);

  { deflateInit is a convenience wrapper around deflateInit_ in FPC's zlib unit }
  ZCompressCheck(deflateInit(zstream, Levels[level]));

  try
    ZInternalCompressStream(zstream, inStream, outStream);
  except
    { Ensure cleanup on any exception }
    deflateEnd(zstream);
    raise;
  end;
end;

{------------------------------------------------------------------------------}
{ Overload that accepts a raw zlib level integer (0..9 or -1)                  }
procedure ZCompressStream(inStream, outStream: TStream; level: Integer);
var
  zstream: TZStream;
begin
  if (inStream = nil) or (outStream = nil) then
    raise EZCompressionError.Create('stream error');

  FillChar(zstream, SizeOf(zstream), 0);
  ZCompressCheck(deflateInit(zstream, level));

  try
    ZInternalCompressStream(zstream, inStream, outStream);
  except
    deflateEnd(zstream);
    raise;
  end;
end;

end.