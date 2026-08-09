// For now this just adds a missing BytesOf overload, might use it
// for other misc helper functions also as needed too later on though

unit wbExtra;

{$mode unleashed}

interface

function BytesOf(const Val: Pointer; const Len: Integer): TBytes; inline;

implementation

function BytesOf(const Val: Pointer; const Len: Integer): TBytes;
begin
  if (Len <= 0) or (Val = nil) then
  begin
    Result := nil;
    Exit;
  end;
  SetLength(Result, Len);
  Move(Val^, Result[0], Len);
end;

end.

