unit TestPrepCache;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TPrepCacheTests = class
  public
    [Test] procedure StoreAndFind;
    [Test] procedure KeyIncludesDialect;
    [Test] procedure LeastRecentlyUsedIsDropped;
    [Test] procedure DropRemovesEntry;
    [Test] procedure CapacityZeroDisables;
  end;

implementation

uses
  System.SysUtils, fbhttp.Protocol, fbhttp.PrepCache;

function Desc(N: Integer): TFbVars;
var
  i: Integer;
begin
  SetLength(Result, N);
  for i := 0 to N - 1 do
  begin
    Result[i].SqlType := 497;
    Result[i].Len := 4;
    Result[i].Name := RawByteString('C' + IntToStr(i));
  end;
end;

procedure TPrepCacheTests.StoreAndFind;
var
  c: TFbPrepCache;
  e: TFbPrepEntry;
  k: RawByteString;
begin
  c := TFbPrepCache.Create(10);
  try
    k := TFbPrepCache.KeyOf(3, 'SELECT 1 FROM RDB$DATABASE');
    Assert.IsNull(c.Find(k));
    c.Store(k, 1, Desc(2), Desc(0), TBytes.Create(21, 4, 0, 1, 0, 0, 0, 1));
    e := c.Find(k);
    Assert.IsNotNull(e);
    Assert.AreEqual(1, e.StmtType);
    Assert.AreEqual(2, Length(e.OutDesc));
    Assert.AreEqual('C1', string(e.OutDesc[1].Name));
    Assert.AreEqual(8, Length(e.PrepInfo));
    Assert.AreEqual(1, c.Count);
    // Storing the same key again replaces the entry.
    c.Store(k, 2, Desc(3), Desc(1), nil);
    Assert.AreEqual(1, c.Count);
    Assert.AreEqual(3, Length(c.Find(k).OutDesc));
  finally
    c.Free;
  end;
end;

procedure TPrepCacheTests.KeyIncludesDialect;
begin
  Assert.AreNotEqual(TFbPrepCache.KeyOf(1, 'SELECT 1'), TFbPrepCache.KeyOf(3, 'SELECT 1'));
  Assert.AreNotEqual(TFbPrepCache.KeyOf(3, 'SELECT 1'), TFbPrepCache.KeyOf(3, 'SELECT 1 '));
end;

procedure TPrepCacheTests.LeastRecentlyUsedIsDropped;
var
  c: TFbPrepCache;
begin
  c := TFbPrepCache.Create(2);
  try
    c.Store('a', 1, nil, nil, nil);
    c.Store('b', 1, nil, nil, nil);
    Assert.IsNotNull(c.Find('a')); // a is now the most recently used
    c.Store('c', 1, nil, nil, nil); // drops b
    Assert.AreEqual(2, c.Count);
    Assert.IsNotNull(c.Find('a'));
    Assert.IsNull(c.Find('b'));
    Assert.IsNotNull(c.Find('c'));
  finally
    c.Free;
  end;
end;

procedure TPrepCacheTests.DropRemovesEntry;
var
  c: TFbPrepCache;
begin
  c := TFbPrepCache.Create(5);
  try
    c.Store('a', 1, nil, nil, nil);
    c.Drop('a');
    c.Drop('missing');
    Assert.IsNull(c.Find('a'));
    Assert.AreEqual(0, c.Count);
  finally
    c.Free;
  end;
end;

procedure TPrepCacheTests.CapacityZeroDisables;
var
  c: TFbPrepCache;
begin
  c := TFbPrepCache.Create(0);
  try
    c.Store('a', 1, nil, nil, nil);
    Assert.IsNull(c.Find('a'));
    Assert.AreEqual(0, c.Count);
  finally
    c.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TPrepCacheTests);
end.
