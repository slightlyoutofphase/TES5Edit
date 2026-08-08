unit System.Zip;

{FPC implementation of the same API (mostly) as Delphi System.Zip}

{$mode unleashed}

interface

uses
  Classes, SysUtils, DateUtils, zflate; 

type
  TZipCompression = (
    zcStored = 0,
    zcShrunk,
    zcReduce1,
    zcReduce2,
    zcReduce3,
    zcReduce4,
    zcImplode,
    zcTokenize,
    zcDeflate,
    zcDeflate64,
    zcPKImplode,
    zcBZIP2 = 12,
    zcLZMA = 14,
    zcTERSE = 18,
    zcLZ77,
    zcWavePack = 97,
    zcPPMdI1
  );

  TZipMode = (zmClosed, zmRead, zmReadWrite, zmWrite);

  TZipHeader = packed record
    MadeByVersion:      UInt16;
    RequiredVersion:    UInt16;
    Flag:               UInt16;
    CompressionMethod:  UInt16;
    ModifiedDateTime:   UInt32;
    CRC32:              UInt32;
    CompressedSize:     UInt32;
    UncompressedSize:   UInt32;
    FileNameLength:     UInt16;
    ExtraFieldLength:   UInt16;
    FileCommentLength:  UInt16;
    DiskNumberStart:    UInt16;
    InternalAttributes: UInt16;
    ExternalAttributes: UInt32;
    LocalHeaderOffset:  UInt32;
    FileName: TBytes;
    ExtraField: TBytes;
    FileComment: TBytes;
    
    function GetUTF8Support: Boolean;
    procedure SetUTF8Support(value: Boolean);
    property UTF8Support: Boolean read GetUTF8Support write SetUTF8Support;
  end;
  PZipHeader = ^TZipHeader;
  TZipFile = class;
  TStreamConstructor = reference to function(InStream: TStream; const ZipFile: TZipFile; const Item: TZipHeader): TStream;
  TZipProgressEvent = procedure(Sender: TObject; const FileName: string; Header: TZipHeader; Position, Total: Int64) of object;

  EZipException = class(Exception);

  TZipFile = class
  private
    FStream: TStream;
    FMode: TZipMode;
    FFiles: array of TZipHeader;
    FDeleted: array of Boolean;
    FComment: string;
    FUTF8Support: Boolean;
    FOnProgress: TZipProgressEvent;

    function GetFileName(Index: Integer): string;
    function GetFileInfo(Index: Integer): TZipHeader;
    function GetFileComment(Index: Integer): string;
    procedure SetFileComment(Index: Integer; const Value: string);
    
    procedure ReadZipStructure;
    procedure WriteZipStructure;
    procedure RebuildZipFile;
    function FindHeader(const FileName: string): Integer;
  public
    class procedure ExtractZipFile(const ZipFileName: string; const Path: string; ZipProgress: TZipProgressEvent = nil);
    class procedure RegisterCompressionHandler(Compression: TZipCompression; CompressStream, DecompressStream: TStreamConstructor);
    class procedure UnRegisterCompressionHandler(Compression: TZipCompression);
    class function IsValid(const ZipFileName: string): Boolean;

    constructor Create;
    destructor Destroy; override;

    procedure Open(const ZipFileName: string; Mode: TZipMode = zmReadWrite); overload;
    procedure Open(ZipFileStream: TStream; Mode: TZipMode = zmReadWrite); overload;
    procedure Close;

    procedure Add(const FileName: string; const ArchiveFileName: string = ''; Compression: TZipCompression = zcDeflate); overload;
    procedure Add(Data: TBytes; const ArchiveFileName: string; Compression: TZipCompression = zcDeflate); overload;
    procedure Add(Data: TStream; const ArchiveFileName: string; Compression: TZipCompression = zcDeflate); overload;
    procedure Add(Data: TStream; LocalHeader: TZipHeader; CentralHeader: PZipHeader = nil); overload;
    procedure AddDirectory(const DirName: string);
    
    procedure Read(const FileName: string; out Bytes: TBytes); overload;
    procedure Read(const FileName: string; out Stream: TStream); overload;
    procedure Read(Index: Integer; out Bytes: TBytes); overload;
    procedure Read(Index: Integer; out Stream: TStream); overload;

    procedure Extract(const FileName: string; const Path: string = ''; CreateSubdirs: Boolean = True); overload;
    procedure Extract(Index: Integer; const Path: string = ''; CreateSubdirs: Boolean = True); overload;
    procedure ExtractAll(const Path: string; CreateSubdirs: Boolean = True);
    
    procedure Delete(const FileName: string); overload;
    procedure Delete(Index: Integer); overload;
    procedure Rename(const FileName, NewName: string);

    function GetFileIndex(const FileName: string): Integer;
    function IndexOf(const FileName: string): Integer;

    property FileName[Index: Integer]: string read GetFileName;
    property FileInfo[Index: Integer]: TZipHeader read GetFileInfo;
    property FileComment[Index: Integer]: string read GetFileComment write SetFileComment;
    property Mode: TZipMode read FMode;
    property Comment: string read FComment write FComment;
    property UTF8Support: Boolean read FUTF8Support write FUTF8Support;
    property OnProgress: TZipProgressEvent read FOnProgress write FOnProgress;
  end;

implementation

const
  LOCAL_FILE_HEADER_SIGNATURE = $04034B50;
  CENTRAL_DIR_SIGNATURE = $02014B50;
  END_OF_CENTRAL_DIR_SIGNATURE = $06054B50;

type
  TLocalFileHeader = packed record
    Signature: UInt32;
    RequiredVersion: UInt16;
    Flag: UInt16;
    CompressionMethod: UInt16;
    ModifiedTime: UInt16;
    ModifiedDate: UInt16;
    CRC32: UInt32;
    CompressedSize: UInt32;
    UncompressedSize: UInt32;
    FileNameLength: UInt16;
    ExtraFieldLength: UInt16;
  end;

  TCentralDirectoryHeader = packed record
    Signature: UInt32;
    MadeByVersion: UInt16;
    RequiredVersion: UInt16;
    Flag: UInt16;
    CompressionMethod: UInt16;
    ModifiedTime: UInt16;
    ModifiedDate: UInt16;
    CRC32: UInt32;
    CompressedSize: UInt32;
    UncompressedSize: UInt32;
    FileNameLength: UInt16;
    ExtraFieldLength: UInt16;
    FileCommentLength: UInt16;
    DiskNumberStart: UInt16;
    InternalAttributes: UInt16;
    ExternalAttributes: UInt32;
    LocalHeaderOffset: UInt32;
  end;

  TEndOfCentralDirectory = packed record
    Signature: UInt32;
    DiskNumber: UInt16;
    StartDiskNumber: UInt16;
    EntriesOnDisk: UInt16;
    TotalEntries: UInt16;
    CentralDirSize: UInt32;
    CentralDirOffset: UInt32;
    CommentLength: UInt16;
  end;

var
  crc_table: array[0..255] of UInt32;

procedure MakeCrcTable;
var
  c: UInt32;
  n, k: Integer;
begin
  for n := 0 to 255 do
  begin
    c := n;
    for k := 0 to 7 do
    begin
      if (c and 1) <> 0 then
        c := $EDB88320 xor (c shr 1)
      else
        c := c shr 1;
    end;
    crc_table[n] := c;
  end;
end;

function CRC32(const Data: TBytes): UInt32;
var
  c: UInt32;
  i: Integer;
begin
  c := $FFFFFFFF;
  for i := 0 to High(Data) do
    c := crc_table[(c xor Data[i]) and $FF] xor (c shr 8);
  Result := c xor $FFFFFFFF;
end;

function CRC32Stream(Stream: TStream): UInt32;
var
  c: UInt32;
  Buffer: array[0..4095] of Byte;
  BytesRead, i: Integer;
begin
  c := $FFFFFFFF;
  var oldPos := Stream.Position;
  Stream.Position := 0;
  repeat
    BytesRead := Stream.Read(Buffer, SizeOf(Buffer));
    if BytesRead <= 0 then Break;
    for i := 0 to BytesRead - 1 do
      c := crc_table[(c xor Buffer[i]) and $FF] xor (c shr 8);
  until False;
  Stream.Position := oldPos;
  Result := c xor $FFFFFFFF;
end;

function StreamToBytes(Stream: TStream): TBytes;
var
  Pos: Int64;
begin
  Pos := Stream.Position;
  SetLength(Result, Stream.Size - Pos);
  if Length(Result) > 0 then
    Stream.ReadBuffer(Result[0], Length(Result));
  Stream.Position := Pos;
end;

function DateTimeToDosTime(const DT: TDateTime): UInt32;
var
  H, M, S, MS: Word;
  Y, Mo, D: Word;
begin
  DecodeDate(DT, Y, Mo, D);
  DecodeTime(DT, H, M, S, MS);
  Result := (S div 2) or (M shl 5) or (H shl 11);
  Result := Result or (D shl 16) or (Mo shl 21) or ((Y - 1980) shl 25);
end;

{ TZipHeader }

function TZipHeader.GetUTF8Support: Boolean;
begin
  Result := (Flag and $0800) <> 0;
end;

procedure TZipHeader.SetUTF8Support(value: Boolean);
begin
  if value then
    Flag := Flag or $0800
  else
    Flag := Flag and not $0800;
end;

{ TZipFile }

constructor TZipFile.Create;
begin
  inherited Create;
  FMode := zmClosed;
  FUTF8Support := True;
end;

destructor TZipFile.Destroy;
begin
  if FMode <> zmClosed then Close;
  inherited Destroy;
end;

class function TZipFile.IsValid(const ZipFileName: string): Boolean;
var
  Sig: UInt32;
begin
  try
    var FS := autofree TFileStream.Create(ZipFileName, fmOpenRead or fmShareDenyNone);
    if FS.Size < 22 then Exit(False);
    FS.Position := FS.Size - 22;
    FS.Read(Sig, 4);
    Result := (Sig = END_OF_CENTRAL_DIR_SIGNATURE);
  except
    Result := False;
  end;
end;

class procedure TZipFile.ExtractZipFile(const ZipFileName: string; const Path: string; ZipProgress: TZipProgressEvent = nil);
begin
  var zip := autofree TZipFile.Create;
  zip.Open(ZipFileName, zmRead);
  zip.OnProgress := ZipProgress;
  zip.ExtractAll(Path);
end;

class procedure TZipFile.RegisterCompressionHandler(Compression: TZipCompression; CompressStream, DecompressStream: TStreamConstructor);
begin
  // Unleashed Pascal natively supports zflate for Deflate. Other handlers could be stored here.
end;

class procedure TZipFile.UnRegisterCompressionHandler(Compression: TZipCompression);
begin
end;

procedure TZipFile.Open(const ZipFileName: string; Mode: TZipMode = zmReadWrite);
var
  FSMode: Word;
begin
  if FMode <> zmClosed then
    raise EZipException.Create($'ZIP file already open.');
    
  var exists := FileExists(ZipFileName);
  match Mode of
    zmRead: FSMode := fmOpenRead or fmShareDenyNone;
    zmReadWrite: 
      if exists then FSMode := fmOpenReadWrite or fmShareDenyWrite
      else FSMode := fmCreate;
    zmWrite: FSMode := fmCreate;
    otherwise raise EZipException.Create('Invalid ZIP mode.');
  end;
  
  FStream := TFileStream.Create(ZipFileName, FSMode);
  FMode := Mode;
  
  try
    if (Mode in [zmRead, zmReadWrite]) and exists then
      ReadZipStructure;
  except
    on E: Exception do
    begin
      FreeAndNil(FStream);
      FMode := zmClosed;
      raise;
    end;
  end;
end;

procedure TZipFile.Open(ZipFileStream: TStream; Mode: TZipMode = zmReadWrite);
begin
  if FMode <> zmClosed then
    raise EZipException.Create($'ZIP file already open.');
    
  FStream := ZipFileStream;
  FMode := Mode;
  
  if Mode in [zmRead, zmReadWrite] then
    ReadZipStructure;
end;

procedure TZipFile.Close;
begin
  if FMode = zmClosed then Exit;
  
  if FMode in [zmWrite, zmReadWrite] then
    WriteZipStructure;
    
  FreeAndNil(FStream);
  FMode := zmClosed;
  SetLength(FFiles, 0);
  SetLength(FDeleted, 0);
end;

procedure TZipFile.ReadZipStructure;
var
  EOCD: TEndOfCentralDirectory;
  Sig: UInt32;
  Offset: Int64;
  CDHeader: TCentralDirectoryHeader;
  Hdr: TZipHeader;
  i: Integer;
begin
  SetLength(FFiles, 0);
  SetLength(FDeleted, 0);
  
  FStream.Position := FStream.Size - SizeOf(TEndOfCentralDirectory);
  var found := False;
  
  for Offset := FStream.Size - SizeOf(TEndOfCentralDirectory) downto 0 do
  begin
    FStream.Position := Offset;
    FStream.Read(Sig, 4);
    if Sig = END_OF_CENTRAL_DIR_SIGNATURE then
    begin
      FStream.Position := Offset;
      FStream.Read(EOCD, SizeOf(EOCD));
      found := True;
      Break;
    end;
  end;
  
  if not found then
    raise EZipException.Create('Invalid ZIP file: EOCD not found.');
    
  SetLength(FFiles, EOCD.TotalEntries);
  SetLength(FDeleted, EOCD.TotalEntries);
  
  FStream.Position := EOCD.CentralDirOffset;
  for i := 0 to EOCD.TotalEntries - 1 do
  begin
    FStream.Read(CDHeader, SizeOf(CDHeader));
    if CDHeader.Signature <> CENTRAL_DIR_SIGNATURE then
      raise EZipException.Create('Invalid Central Directory signature.');
      
    Hdr.MadeByVersion := CDHeader.MadeByVersion;
    Hdr.RequiredVersion := CDHeader.RequiredVersion;
    Hdr.Flag := CDHeader.Flag;
    Hdr.CompressionMethod := CDHeader.CompressionMethod;
    Hdr.ModifiedDateTime := (CDHeader.ModifiedDate shl 16) or CDHeader.ModifiedTime;
    Hdr.CRC32 := CDHeader.CRC32;
    Hdr.CompressedSize := CDHeader.CompressedSize;
    Hdr.UncompressedSize := CDHeader.UncompressedSize;
    Hdr.FileNameLength := CDHeader.FileNameLength;
    Hdr.ExtraFieldLength := CDHeader.ExtraFieldLength;
    Hdr.FileCommentLength := CDHeader.FileCommentLength;
    Hdr.DiskNumberStart := CDHeader.DiskNumberStart;
    Hdr.InternalAttributes := CDHeader.InternalAttributes;
    Hdr.ExternalAttributes := CDHeader.ExternalAttributes;
    Hdr.LocalHeaderOffset := CDHeader.LocalHeaderOffset;
    
    SetLength(Hdr.FileName, Hdr.FileNameLength);
    FStream.Read(Hdr.FileName[0], Hdr.FileNameLength);
    
    SetLength(Hdr.ExtraField, Hdr.ExtraFieldLength);
    if Hdr.ExtraFieldLength > 0 then
      FStream.Read(Hdr.ExtraField[0], Hdr.ExtraFieldLength);
      
    SetLength(Hdr.FileComment, Hdr.FileCommentLength);
    if Hdr.FileCommentLength > 0 then
      FStream.Read(Hdr.FileComment[0], Hdr.FileCommentLength);
      
    FFiles[i] := Hdr;
    FDeleted[i] := False;
  end;
end;

procedure TZipFile.Add(const FileName: string; const ArchiveFileName: string = ''; Compression: TZipCompression = zcDeflate);
var
  arcName: string;
begin
  if FMode = zmClosed then raise EZipException.Create('ZIP file is closed.');
  if FMode = zmRead then raise EZipException.Create('ZIP file is read-only.');
  
  if ArchiveFileName = '' then
    arcName := ExtractFileName(FileName)
  else
    arcName := ArchiveFileName;
    
  var FS := autofree TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
  Add(FS, arcName, Compression);
end;

procedure TZipFile.Add(Data: TBytes; const ArchiveFileName: string; Compression: TZipCompression = zcDeflate);
begin
  var MS := autofree TMemoryStream.Create;
  if Length(Data) > 0 then
    MS.WriteBuffer(Data[0], Length(Data));
  MS.Position := 0;
  Add(MS, ArchiveFileName, Compression);
end;

procedure TZipFile.Add(Data: TStream; const ArchiveFileName: string; Compression: TZipCompression = zcDeflate);
var
  LocalHeader: TLocalFileHeader;
  Header: TZipHeader;
  Crc, UncompSize, CompSize: UInt32;
  CompressedData: TBytes;
  Offset: UInt32;
begin
  if FMode = zmClosed then raise EZipException.Create('ZIP file is closed.');
  if FMode = zmRead then raise EZipException.Create('ZIP file is read-only.');

  Crc := CRC32Stream(Data);
  UncompSize := Data.Size;
  
  var CompMethod: UInt16 := 0;
  match Compression of
    zcStored: CompMethod := 0;
    zcDeflate: CompMethod := 8;
    otherwise raise EZipException.Create('Unsupported compression method.');
  end;
  
  if CompMethod = 8 then
  begin
    var inBytes := StreamToBytes(Data);
    var outBytes := gzdeflate(inBytes, 9);
    if Length(outBytes) = 0 then
      raise EZipException.Create('Deflate compression failed.');
    CompressedData := outBytes;
    CompSize := Length(CompressedData);
  end
  else
  begin
    CompSize := UncompSize;
    CompressedData := StreamToBytes(Data);
  end;

  Offset := FStream.Position;

  LocalHeader.Signature := LOCAL_FILE_HEADER_SIGNATURE;
  LocalHeader.RequiredVersion := 20;
  LocalHeader.Flag := 0;
  if FUTF8Support then LocalHeader.Flag := LocalHeader.Flag or $0800; 
  LocalHeader.CompressionMethod := CompMethod;
  var dt := DateTimeToDosTime(Now);
  LocalHeader.ModifiedTime := dt and $FFFF;
  LocalHeader.ModifiedDate := (dt shr 16) and $FFFF;
  LocalHeader.CRC32 := Crc;
  LocalHeader.CompressedSize := CompSize;
  LocalHeader.UncompressedSize := UncompSize;
  var fnBytes := TEncoding.UTF8.GetBytes(ArchiveFileName);
  LocalHeader.FileNameLength := Length(fnBytes);
  LocalHeader.ExtraFieldLength := 0;

  FStream.Write(LocalHeader, SizeOf(LocalHeader));
  if Length(fnBytes) > 0 then
    FStream.Write(fnBytes[0], Length(fnBytes));
    
  if Length(CompressedData) > 0 then
    FStream.Write(CompressedData[0], Length(CompressedData));

  Header.MadeByVersion := 20;
  Header.RequiredVersion := 20;
  Header.Flag := LocalHeader.Flag;
  Header.CompressionMethod := CompMethod;
  Header.ModifiedDateTime := dt;
  Header.CRC32 := Crc;
  Header.CompressedSize := CompSize;
  Header.UncompressedSize := UncompSize;
  Header.FileNameLength := LocalHeader.FileNameLength;
  Header.ExtraFieldLength := 0;
  Header.FileCommentLength := 0;
  Header.DiskNumberStart := 0;
  Header.InternalAttributes := 0;
  Header.ExternalAttributes := 0;
  Header.LocalHeaderOffset := Offset;
  Header.FileName := fnBytes;
  SetLength(Header.ExtraField, 0);
  SetLength(Header.FileComment, 0);
  
  var idx := Length(FFiles);
  SetLength(FFiles, idx + 1);
  SetLength(FDeleted, idx + 1);
  FFiles[idx] := Header;
  FDeleted[idx] := False;

  if Assigned(FOnProgress) then
    FOnProgress(Self, ArchiveFileName, Header, CompSize, UncompSize);
end;

procedure TZipFile.Add(Data: TStream; LocalHeader: TZipHeader; CentralHeader: PZipHeader = nil);
var
  Offset: UInt32;
  idx: Integer;
  LH: TLocalFileHeader;
begin
  if FMode = zmClosed then raise EZipException.Create('ZIP file is closed.');
  if FMode = zmRead then raise EZipException.Create('ZIP file is read-only.');

  Offset := FStream.Position;
  
  var fnBytes := LocalHeader.FileName;
  var exBytes := LocalHeader.ExtraField;
  
  LH.Signature := LOCAL_FILE_HEADER_SIGNATURE;
  LH.RequiredVersion := LocalHeader.RequiredVersion;
  LH.Flag := LocalHeader.Flag;
  LH.CompressionMethod := LocalHeader.CompressionMethod;
  LH.ModifiedTime := LocalHeader.ModifiedDateTime and $FFFF;
  LH.ModifiedDate := (LocalHeader.ModifiedDateTime shr 16) and $FFFF;
  LH.CRC32 := LocalHeader.CRC32;
  LH.CompressedSize := LocalHeader.CompressedSize;
  LH.UncompressedSize := LocalHeader.UncompressedSize;
  LH.FileNameLength := LocalHeader.FileNameLength;
  LH.ExtraFieldLength := LocalHeader.ExtraFieldLength;
  
  FStream.Write(LH, SizeOf(LH));
  if Length(fnBytes) > 0 then FStream.Write(fnBytes[0], Length(fnBytes));
  if Length(exBytes) > 0 then FStream.Write(exBytes[0], Length(exBytes));
  
  var buf := StreamToBytes(Data);
  if Length(buf) > 0 then FStream.Write(buf[0], Length(buf));
  
  var Hdr := LocalHeader;
  Hdr.LocalHeaderOffset := Offset;
  if Assigned(CentralHeader) then
  begin
    Hdr.MadeByVersion := CentralHeader^.MadeByVersion;
    Hdr.FileCommentLength := CentralHeader^.FileCommentLength;
    Hdr.DiskNumberStart := CentralHeader^.DiskNumberStart;
    Hdr.InternalAttributes := CentralHeader^.InternalAttributes;
    Hdr.ExternalAttributes := CentralHeader^.ExternalAttributes;
    Hdr.FileComment := CentralHeader^.FileComment;
  end;
  
  idx := Length(FFiles);
  SetLength(FFiles, idx + 1);
  SetLength(FDeleted, idx + 1);
  FFiles[idx] := Hdr;
  FDeleted[idx] := False;
end;

procedure TZipFile.AddDirectory(const DirName: string);
  procedure AddSubDir(const Path, RelPath: string);
  var
    SR: TSearchRec;
  begin
    if FindFirst(Path + '*', faAnyFile, SR) = 0 then
    begin
      try
        repeat
          if (SR.Name <> '.') and (SR.Name <> '..') then
          begin
            var full := Path + SR.Name;
            if (SR.Attr and faDirectory) <> 0 then
              AddSubDir(full, RelPath + SR.Name + '/')
            else
              Add(full, RelPath + SR.Name);
          end;
        until FindNext(SR) <> 0;
      finally
        FindClose(SR);
      end;
    end;
  end;
begin
  AddSubDir(IncludeTrailingPathDelimiter(DirName), '');
end;

procedure TZipFile.Read(const FileName: string; out Bytes: TBytes);
var
  idx: Integer;
begin
  idx := GetFileIndex(FileName);
  if idx < 0 then raise EZipException.Create($'File {FileName} not found.');
  Read(idx, Bytes);
end;

procedure TZipFile.Read(const FileName: string; out Stream: TStream);
var
  Bytes: TBytes;
begin
  Read(FileName, Bytes);
  Stream := TMemoryStream.Create;
  if Length(Bytes) > 0 then
    Stream.WriteBuffer(Bytes[0], Length(Bytes));
  Stream.Position := 0;
end;

procedure TZipFile.Read(Index: Integer; out Bytes: TBytes);
var
  Hdr: TZipHeader;
  LocalHeader: TLocalFileHeader;
  Sig: UInt32;
  CompData: TBytes;
begin
  if FMode = zmClosed then raise EZipException.Create('ZIP file is closed.');
  if (Index < 0) or (Index >= Length(FFiles)) then raise EZipException.Create('Index out of bounds.');
  if FDeleted[Index] then raise EZipException.Create('File is deleted.');
  
  Hdr := FFiles[Index];
  FStream.Position := Hdr.LocalHeaderOffset;
  FStream.Read(Sig, 4);
  if Sig <> LOCAL_FILE_HEADER_SIGNATURE then
    raise EZipException.Create('Invalid Local Header signature.');
    
  FStream.Read(LocalHeader, SizeOf(LocalHeader));
  FStream.Position := FStream.Position + LocalHeader.FileNameLength + LocalHeader.ExtraFieldLength;
  
  SetLength(CompData, Hdr.CompressedSize);
  if Hdr.CompressedSize > 0 then
    FStream.Read(CompData[0], Hdr.CompressedSize);
    
  match Hdr.CompressionMethod of
    0: Bytes := CompData;
    8: 
      begin
        Bytes := gzinflate(CompData);
        if Length(Bytes) <> Hdr.UncompressedSize then
          raise EZipException.Create('Inflate failed.');
      end;
    otherwise raise EZipException.Create('Unsupported compression method.');
  end;
  
  if CRC32(Bytes) <> Hdr.CRC32 then
    raise EZipException.Create('CRC32 mismatch.');
end;

procedure TZipFile.Read(Index: Integer; out Stream: TStream);
var
  Bytes: TBytes;
begin
  Read(Index, Bytes);
  Stream := TMemoryStream.Create;
  if Length(Bytes) > 0 then
    Stream.WriteBuffer(Bytes[0], Length(Bytes));
  Stream.Position := 0;
end;

procedure TZipFile.Extract(Index: Integer; const Path: string = ''; CreateSubdirs: Boolean = True);
var
  Hdr: TZipHeader;
  LocalHeader: TLocalFileHeader;
  Sig: UInt32;
  CompData, UncompData: TBytes;
  OutPath, fn: string;
begin
  if FMode = zmClosed then raise EZipException.Create('ZIP file is closed.');
  if (Index < 0) or (Index >= Length(FFiles)) then raise EZipException.Create('Index out of bounds.');
  if FDeleted[Index] then raise EZipException.Create('File is deleted.');
  
  Hdr := FFiles[Index];
  FStream.Position := Hdr.LocalHeaderOffset;
  FStream.Read(Sig, 4);
  if Sig <> LOCAL_FILE_HEADER_SIGNATURE then
    raise EZipException.Create('Invalid Local Header signature.');
    
  FStream.Read(LocalHeader, SizeOf(LocalHeader));
  FStream.Position := FStream.Position + LocalHeader.FileNameLength + LocalHeader.ExtraFieldLength;
  
  SetLength(CompData, Hdr.CompressedSize);
  if Hdr.CompressedSize > 0 then
    FStream.Read(CompData[0], Hdr.CompressedSize);
    
  match Hdr.CompressionMethod of
    0: UncompData := CompData;
    8: 
      begin
        UncompData := gzinflate(CompData);
        if Length(UncompData) <> Hdr.UncompressedSize then
          raise EZipException.Create('Inflate failed.');
      end;
    otherwise raise EZipException.Create('Unsupported compression method.');
  end;
  
  if CRC32(UncompData) <> Hdr.CRC32 then
    raise EZipException.Create('CRC32 mismatch.');
    
  fn := TEncoding.UTF8.GetString(Hdr.FileName);
  if Path <> '' then
    OutPath := IncludeTrailingPathDelimiter(Path) + fn
  else
    OutPath := fn;
    
  if CreateSubdirs then
    ForceDirectories(ExtractFilePath(OutPath));
    
  var FS := autofree TFileStream.Create(OutPath, fmCreate);
  if Length(UncompData) > 0 then
    FS.WriteBuffer(UncompData[0], Length(UncompData));
end;

procedure TZipFile.Extract(const FileName: string; const Path: string = ''; CreateSubdirs: Boolean = True);
var
  idx: Integer;
begin
  idx := GetFileIndex(FileName);
  if idx < 0 then raise EZipException.Create($'File {FileName} not found.');
  Extract(idx, Path, CreateSubdirs);
end;

procedure TZipFile.ExtractAll(const Path: string; CreateSubdirs: Boolean = True);
var
  i: Integer;
  zipPath: string;
begin
  if FMode = zmClosed then raise EZipException.Create('ZIP file is closed.');
  
  if FStream is TFileStream then
  begin
    zipPath := TFileStream(FStream).FileName;
    // Safe multi-threaded extraction using parallel for and thread-local file handles
    for parallel var i := 0 to High(FFiles) do
    begin
      if not FDeleted[i] then
      begin
        var localZip := autofree TZipFile.Create;
        localZip.Open(zipPath, zmRead);
        localZip.Extract(i, Path, CreateSubdirs);
      end;
    end;
  end
  else
  begin
    for i := 0 to High(FFiles) do
      if not FDeleted[i] then Extract(i, Path, CreateSubdirs);
  end;
end;

procedure TZipFile.Delete(Index: Integer);
begin
  if FMode = zmClosed then raise EZipException.Create('ZIP file is closed.');
  if FMode = zmRead then raise EZipException.Create('ZIP file is read-only.');
  if (Index < 0) or (Index >= Length(FFiles)) then raise EZipException.Create('Index out of bounds.');
  
  FDeleted[Index] := True;
  RebuildZipFile;
end;

procedure TZipFile.Delete(const FileName: string);
var
  idx: Integer;
begin
  idx := GetFileIndex(FileName);
  if idx < 0 then raise EZipException.Create($'File {FileName} not found.');
  Delete(idx);
end;

procedure TZipFile.Rename(const FileName, NewName: string);
var
  idx: Integer;
  newBytes: TBytes;
begin
  idx := GetFileIndex(FileName);
  if idx < 0 then raise EZipException.Create($'File {FileName} not found.');
  if FMode = zmRead then raise EZipException.Create('ZIP file is read-only.');
  
  newBytes := TEncoding.UTF8.GetBytes(NewName);
  FFiles[idx].FileName := newBytes;
  FFiles[idx].FileNameLength := Length(newBytes);
  RebuildZipFile;
end;

procedure TZipFile.RebuildZipFile;
var
  TempName: string;
  i: Integer;
  LocalHeader: TLocalFileHeader;
  Sig: UInt32;
  CompData: TBytes;
  Hdr: TZipHeader;
begin
  if Length(FFiles) = 0 then
  begin
    if FStream is TMemoryStream then
      TMemoryStream(FStream).Clear
    else if FStream is TFileStream then
      TFileStream(FStream).Size := 0;
    Exit;
  end;

  TempName := GetTempDir + 'ziptemp_' + IntToStr(GetTickCount64) + '.tmp';
  var TempStream := autofree TFileStream.Create(TempName, fmCreate);
  defer DeleteFile(TempName);
  
  var newFiles: array of TZipHeader;
  var newDeleted: array of Boolean;
  SetLength(newFiles, 0);
  SetLength(newDeleted, 0);
  
  for i := 0 to High(FFiles) do
  begin
    if not FDeleted[i] then
    begin
      Hdr := FFiles[i];
      FStream.Position := Hdr.LocalHeaderOffset;
      FStream.Read(Sig, 4);
      FStream.Read(LocalHeader, SizeOf(LocalHeader));
      FStream.Position := FStream.Position + LocalHeader.FileNameLength + LocalHeader.ExtraFieldLength;
      
      SetLength(CompData, Hdr.CompressedSize);
      if Hdr.CompressedSize > 0 then
        FStream.Read(CompData[0], Hdr.CompressedSize);
        
      var newOffset := TempStream.Position;
      LocalHeader.CRC32 := Hdr.CRC32;
      TempStream.Write(LocalHeader, SizeOf(LocalHeader));
      if Hdr.FileNameLength > 0 then TempStream.Write(Hdr.FileName[0], Hdr.FileNameLength);
      if Hdr.ExtraFieldLength > 0 then TempStream.Write(Hdr.ExtraField[0], Hdr.ExtraFieldLength);
      if Length(CompData) > 0 then TempStream.Write(CompData[0], Length(CompData));
      
      Hdr.LocalHeaderOffset := newOffset;
      
      var idx := Length(newFiles);
      SetLength(newFiles, idx + 1);
      SetLength(newDeleted, idx + 1);
      newFiles[idx] := Hdr;
      newDeleted[idx] := False;
    end;
  end;
  
  FFiles := newFiles;
  FDeleted := newDeleted;
  
  if FStream is TMemoryStream then
    TMemoryStream(FStream).Clear
  else if FStream is TFileStream then
    TFileStream(FStream).Size := 0;
    
  FStream.Position := 0;
  TempStream.Position := 0;
  FStream.CopyFrom(TempStream, TempStream.Size);
end;

procedure TZipFile.WriteZipStructure;
var
  CDHeader: TCentralDirectoryHeader;
  EOCD: TEndOfCentralDirectory;
  CDStart, CDSize: Int64;
  i: Integer;
begin
  CDStart := FStream.Position;
  for i := 0 to High(FFiles) do
  begin
    var Hdr := FFiles[i];
    CDHeader.Signature := CENTRAL_DIR_SIGNATURE;
    CDHeader.MadeByVersion := Hdr.MadeByVersion;
    CDHeader.RequiredVersion := Hdr.RequiredVersion;
    CDHeader.Flag := Hdr.Flag;
    CDHeader.CompressionMethod := Hdr.CompressionMethod;
    CDHeader.ModifiedTime := Hdr.ModifiedDateTime and $FFFF;
    CDHeader.ModifiedDate := (Hdr.ModifiedDateTime shr 16) and $FFFF;
    CDHeader.CRC32 := Hdr.CRC32;
    CDHeader.CompressedSize := Hdr.CompressedSize;
    CDHeader.UncompressedSize := Hdr.UncompressedSize;
    CDHeader.FileNameLength := Hdr.FileNameLength;
    CDHeader.ExtraFieldLength := Hdr.ExtraFieldLength;
    CDHeader.FileCommentLength := Hdr.FileCommentLength;
    CDHeader.DiskNumberStart := Hdr.DiskNumberStart;
    CDHeader.InternalAttributes := Hdr.InternalAttributes;
    CDHeader.ExternalAttributes := Hdr.ExternalAttributes;
    CDHeader.LocalHeaderOffset := Hdr.LocalHeaderOffset;
    
    FStream.Write(CDHeader, SizeOf(CDHeader));
    if Hdr.FileNameLength > 0 then
      FStream.Write(Hdr.FileName[0], Hdr.FileNameLength);
    if Hdr.ExtraFieldLength > 0 then
      FStream.Write(Hdr.ExtraField[0], Hdr.ExtraFieldLength);
    if Hdr.FileCommentLength > 0 then
      FStream.Write(Hdr.FileComment[0], Hdr.FileCommentLength);
  end;
  
  CDSize := FStream.Position - CDStart;
  
  EOCD.Signature := END_OF_CENTRAL_DIR_SIGNATURE;
  EOCD.DiskNumber := 0;
  EOCD.StartDiskNumber := 0;
  EOCD.EntriesOnDisk := Length(FFiles);
  EOCD.TotalEntries := Length(FFiles);
  EOCD.CentralDirSize := CDSize;
  EOCD.CentralDirOffset := CDStart;
  EOCD.CommentLength := 0;
  
  FStream.Write(EOCD, SizeOf(EOCD));
end;

function TZipFile.FindHeader(const FileName: string): Integer;
var
  i: Integer;
  fnBytes: TBytes;
  ismatch: Boolean;
begin
  fnBytes := TEncoding.UTF8.GetBytes(FileName);
  for i := 0 to High(FFiles) do
  begin
    if not FDeleted[i] and (FFiles[i].FileNameLength = Length(fnBytes)) then
    begin
      ismatch := True;
      for var j := 0 to High(fnBytes) do
        if FFiles[i].FileName[j] <> fnBytes[j] then
        begin
          ismatch := False;
          Break;
        end;
      if ismatch then Exit(i);
    end;
  end;
  Result := -1;
end;

function TZipFile.GetFileIndex(const FileName: string): Integer;
begin
  Result := FindHeader(FileName);
end;

function TZipFile.IndexOf(const FileName: string): Integer;
begin
  Result := GetFileIndex(FileName);
end;

function TZipFile.GetFileName(Index: Integer): string;
begin
  if (Index < 0) or (Index >= Length(FFiles)) then raise EZipException.Create('Index out of bounds.');
  Result := TEncoding.UTF8.GetString(FFiles[Index].FileName);
end;

function TZipFile.GetFileInfo(Index: Integer): TZipHeader;
begin
  if (Index < 0) or (Index >= Length(FFiles)) then raise EZipException.Create('Index out of bounds.');
  Result := FFiles[Index];
end;

function TZipFile.GetFileComment(Index: Integer): string;
begin
  if (Index < 0) or (Index >= Length(FFiles)) then raise EZipException.Create('Index out of bounds.');
  Result := TEncoding.UTF8.GetString(FFiles[Index].FileComment);
end;

procedure TZipFile.SetFileComment(Index: Integer; const Value: string);
var
  cmtBytes: TBytes;
begin
  if (Index < 0) or (Index >= Length(FFiles)) then raise EZipException.Create('Index out of bounds.');
  if FMode = zmRead then raise EZipException.Create('ZIP file is read-only.');
  cmtBytes := TEncoding.UTF8.GetBytes(Value);
  FFiles[Index].FileComment := cmtBytes;
  FFiles[Index].FileCommentLength := Length(cmtBytes);
end;

initialization
  MakeCrcTable;
end.
