unit fbhttp.Handles;

{ Thread-safe table of the handles given to the driver. Values never repeat,
  so a stale handle is detected instead of reaching a new object. ASCII only. }

interface

uses
  System.SysUtils, System.SyncObjs, System.Generics.Collections, fbhttp.IBase;

type
  THandleTable = class
  private
    FLock: TCriticalSection;
    FItems: TObjectDictionary<FB_API_HANDLE, TObject>;
    FNext: FB_API_HANDLE;
  public
    constructor Create;
    destructor Destroy; override;
    function Add(Obj: TObject): FB_API_HANDLE;
    // Returns the object, or raises EFbCode(BadCode) when the handle is
    // unknown or of another class.
    function Get(H: FB_API_HANDLE; Cls: TClass; BadCode: ISC_STATUS): TObject;
    function TryGet(H: FB_API_HANDLE; Cls: TClass; out Obj: TObject): Boolean;
    procedure Remove(H: FB_API_HANDLE); // frees the object
  end;

var
  Handles: THandleTable;

implementation

uses
  fbhttp.Status;

constructor THandleTable.Create;
begin
  FLock := TCriticalSection.Create;
  FItems := TObjectDictionary<FB_API_HANDLE, TObject>.Create([doOwnsValues]);
  FNext := $1000; // small values look like uninitialized memory
end;

destructor THandleTable.Destroy;
begin
  FItems.Free;
  FLock.Free;
  inherited;
end;

function THandleTable.Add(Obj: TObject): FB_API_HANDLE;
begin
  FLock.Enter;
  try
    Inc(FNext);
    if FNext = 0 then
      FNext := $1000;
    Result := FNext;
    FItems.Add(Result, Obj);
  finally
    FLock.Leave;
  end;
end;

function THandleTable.TryGet(H: FB_API_HANDLE; Cls: TClass; out Obj: TObject): Boolean;
begin
  FLock.Enter;
  try
    Result := FItems.TryGetValue(H, Obj) and (Obj is Cls);
  finally
    FLock.Leave;
  end;
end;

function THandleTable.Get(H: FB_API_HANDLE; Cls: TClass; BadCode: ISC_STATUS): TObject;
begin
  if not TryGet(H, Cls, Result) then
    case BadCode of
      isc_bad_db_handle: raise EFbCode.Create(BadCode, 'invalid database handle (no active connection)');
      isc_bad_trans_handle: raise EFbCode.Create(BadCode, 'invalid transaction handle (expecting explicit transaction start)');
      isc_bad_stmt_handle: raise EFbCode.Create(BadCode, 'invalid statement handle');
      isc_bad_segstr_handle: raise EFbCode.Create(BadCode, 'invalid BLOB handle');
    else
      raise EFbCode.Create(BadCode, 'invalid handle');
    end;
end;

procedure THandleTable.Remove(H: FB_API_HANDLE);
begin
  FLock.Enter;
  try
    FItems.Remove(H);
  finally
    FLock.Leave;
  end;
end;

initialization
  Handles := THandleTable.Create;

finalization
  Handles.Free;
end.
