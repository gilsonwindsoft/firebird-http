unit fbhttp.PrepCache;

{ Per-attachment cache of PREPARE results, keyed by dialect and SQL text
  (exact bytes). A hit lets the DLL answer describe and sql_info locally and
  send the real PREPARE with the EXECUTE. Bounded, least recently used entry
  dropped first. Not thread-safe: callers hold the attachment lock. ASCII only. }

interface

uses
  System.Generics.Collections, fbhttp.Protocol;

type
  TFbPrepEntry = class
    Key: RawByteString;
    StmtType: Integer;
    OutDesc, InDesc: TFbVars;
    PrepInfo: TBytes;
  end;

  TFbPrepCache = class
  private
    FCapacity: Integer;
    FByKey: TObjectDictionary<RawByteString, TFbPrepEntry>; // owns the entries
    FOrder: TList<TFbPrepEntry>;                            // last = most recently used
  public
    // Capacity 0 disables the cache: Find never hits, Store does nothing.
    constructor Create(Capacity: Integer);
    destructor Destroy; override;
    class function KeyOf(Dialect: Word; const Sql: RawByteString): RawByteString; static;
    // Nil on a miss. A hit becomes the most recently used entry.
    function Find(const Key: RawByteString): TFbPrepEntry;
    procedure Store(const Key: RawByteString; StmtType: Integer; const OutDesc, InDesc: TFbVars; const PrepInfo: TBytes);
    procedure Drop(const Key: RawByteString);
    function Count: Integer;
    property Capacity: Integer read FCapacity;
  end;

implementation

uses
  System.SysUtils;

constructor TFbPrepCache.Create(Capacity: Integer);
begin
  FCapacity := Capacity;
  FByKey := TObjectDictionary<RawByteString, TFbPrepEntry>.Create([doOwnsValues]);
  FOrder := TList<TFbPrepEntry>.Create;
end;

destructor TFbPrepCache.Destroy;
begin
  FOrder.Free;
  FByKey.Free;
  inherited;
end;

class function TFbPrepCache.KeyOf(Dialect: Word; const Sql: RawByteString): RawByteString;
begin
  Result := RawByteString(IntToStr(Dialect) + ':') + Sql;
end;

function TFbPrepCache.Find(const Key: RawByteString): TFbPrepEntry;
begin
  if (FCapacity <= 0) or not FByKey.TryGetValue(Key, Result) then
    Exit(nil);
  FOrder.Remove(Result);
  FOrder.Add(Result);
end;

procedure TFbPrepCache.Store(const Key: RawByteString; StmtType: Integer; const OutDesc, InDesc: TFbVars; const PrepInfo: TBytes);
var
  e: TFbPrepEntry;
begin
  if FCapacity <= 0 then
    Exit;
  Drop(Key);
  while FOrder.Count >= FCapacity do
    Drop(FOrder[0].Key);
  e := TFbPrepEntry.Create;
  e.Key := Key;
  e.StmtType := StmtType;
  e.OutDesc := Copy(OutDesc);
  e.InDesc := Copy(InDesc);
  e.PrepInfo := Copy(PrepInfo);
  FByKey.Add(Key, e);
  FOrder.Add(e);
end;

procedure TFbPrepCache.Drop(const Key: RawByteString);
var
  e: TFbPrepEntry;
begin
  if FByKey.TryGetValue(Key, e) then
  begin
    FOrder.Remove(e);
    FByKey.Remove(Key); // frees e
  end;
end;

function TFbPrepCache.Count: Integer;
begin
  Result := FOrder.Count;
end;

end.
