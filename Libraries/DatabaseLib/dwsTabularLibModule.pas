unit dwsTabularLibModule;

interface

uses
  System.SysUtils, System.Classes, dwsComp, dwsExprs, dwsSymbols;

type
  TdwsTabularLib = class(TDataModule)
    dwsTabular: TdwsUnit;
    procedure dwsTabularClassesTabularDataConstructorsCreateFromDataSetEval(
      Info: TProgramInfo; var ExtObject: TObject);
    procedure dwsTabularClassesTabularDataCleanUp(ExternalObject: TObject);
    procedure dwsTabularClassesTabularDataMethodsEvaluateAggregateEval(
      Info: TProgramInfo; ExtObject: TObject);
    procedure dwsTabularClassesTabularDataMethodsEvaluateNewColumnEval(
      Info: TProgramInfo; ExtObject: TObject);
    procedure dwsTabularClassesTabularDataMethodsExportToSeparatedEval(
      Info: TProgramInfo; ExtObject: TObject);
    procedure dwsTabularClassesTabularDataMethodsDropColumnEval(
      Info: TProgramInfo; ExtObject: TObject);
    procedure dwsTabularClassesTabularDataMethodsAddColumnEval(
      Info: TProgramInfo; ExtObject: TObject);
    procedure dwsTabularClassesTabularDataConstructorsCreateEval(
      Info: TProgramInfo; var ExtObject: TObject);
  private
    { Private declarations }
    FScript : TDelphiWebScript;
  protected
    procedure SetScript(const val : TDelphiWebScript);
  public
    property Script : TDelphiWebScript read FScript write SetScript;
  end;

implementation

uses dwsUtils, dwsTabular, dwsDatabaseLibModule, dwsDatabase, dwsJIT;

{$R *.dfm}

function PrepareExprFromOpcode(const tabular : TdwsTabular; const opCodes : IScriptDynArray) : TdwsTabularExpression;
var
   bufStr : String;
   i : Integer;
begin
   Result := TdwsTabularExpression.Create(tabular);
   try
      for i := 0 to opCodes.ArrayLength-1 do begin
         case opCodes.VarType(i) of
            varDouble, varInt64 :
               Result.PushConst(opCodes.AsFloat[i]);
         else
            opCodes.EvalAsString(i, bufStr);
            Result.Opcode(bufStr);
         end;
      end;
   except
      Result.Free;
      raise;
   end;
end;

function ParseOptions(const options : IScriptDynArray) : TdwsTabular;
var
   buf : String;
   autoJIT : Boolean;
begin
   autoJIT := True;

   Result := TdwsTabular.Create;
   for var i := 0 to options.ArrayLength-1 do begin
      options.EvalAsString(i, buf);
      if buf = 'jit' then
         Result.InitializeJIT
      else if buf = 'nojit' then
         autoJIT := False;
   end;
   if autoJIT then begin
      // JIT overhead is not worth it for smaller datasets
      if Result.RowCount >= 256 then
         Result.InitializeJIT;
   end;
end;

procedure TdwsTabularLib.SetScript(const val : TDelphiWebScript);
begin
   dwsTabular.Script := val;
end;

procedure TdwsTabularLib.dwsTabularClassesTabularDataCleanUp(
  ExternalObject: TObject);
begin
   ExternalObject.Free;
end;

procedure TdwsTabularLib.dwsTabularClassesTabularDataConstructorsCreateEval(
  Info: TProgramInfo; var ExtObject: TObject);
begin
   var tabular := ParseOptions(Info.ParamAsScriptDynArray[0]);
   ExtObject := tabular;
end;

procedure TdwsTabularLib.dwsTabularClassesTabularDataConstructorsCreateFromDataSetEval(
  Info: TProgramInfo; var ExtObject: TObject);
var
   dsFields : array of IdwsDataField;
   dsNumeric : array of Boolean;
   buf : String;
begin
   var ds := Info.ParamAsScriptObj[0];
   var scriptDS := (ds.ExternalObject as TScriptDataSet).Intf;

   var tabular := ParseOptions(Info.ParamAsScriptDynArray[1]);
   ExtObject := tabular;

   var nbFields := scriptDS.FieldCount;
   SetLength(dsFields, nbFields);
   SetLength(dsNumeric, nbFields);
   for var i := 0 to nbFields-1 do begin
      dsFields[i] := scriptDS.Fields[i];
      var declaredType := LowerCase(dsFields[i].DeclaredType);
      dsNumeric[i] := (declaredType = 'double') or (declaredType = 'float') or (declaredType = 'numeric');
      if dsNumeric[i] then
         tabular.AddColumn(dsFields[i].Name, [ tcvNumeric ])
      else tabular.AddColumn(dsFields[i].Name)
   end;

   while not scriptDS.Eof do begin
      for var i := 0 to nbFields-1 do begin
         var column := tabular.ColumnData[i];
         if dsNumeric[i] then begin
            if dsFields[i].IsNull then
               column.AddNull
            else column.Add(dsFields[i].AsFloat);
         end else begin
            dsFields[i].GetAsString(buf);
            column.Add(buf, dsFields[i].AsFloat);
         end;
      end;
      scriptDS.Next;
   end;
end;

procedure TdwsTabularLib.dwsTabularClassesTabularDataMethodsAddColumnEval(
  Info: TProgramInfo; ExtObject: TObject);
begin
   var tabular := Info.ScriptObj.ExternalObject as TdwsTabular;
   var name := Info.ParamAsString[0];
   if name = '' then
      raise Exception.Create('Name should not be empty');
   if tabular.IndexOfColumn(name) >= 0 then
      raise Exception.CreateFmt('Column with name "%s" already exists', [ name ]);
   var values := Info.ParamAsScriptDynArray[1];
   if (tabular.ColumnCount > 0) and (values.ArrayLength <> tabular.RowCount) then
      raise Exception.CreateFmt('Mismatching number of elements (got %d, expected %d)',
                                [ values.ArrayLength, tabular.RowCount ]);
   var column := tabular.AddColumn(name);
   for var i := 0 to values.ArrayLength-1 do
      column.Add(values.AsFloat[i]);
end;

procedure TdwsTabularLib.dwsTabularClassesTabularDataMethodsDropColumnEval(
  Info: TProgramInfo; ExtObject: TObject);
begin
   var tabular := Info.ScriptObj.ExternalObject as TdwsTabular;
   info.ResultAsBoolean := tabular.DropColumn(Info.ParamAsString[0]);
end;

procedure TdwsTabularLib.dwsTabularClassesTabularDataMethodsEvaluateAggregateEval(
  Info: TProgramInfo; ExtObject: TObject);
begin
   var tabular := Info.ScriptObj.ExternalObject as TdwsTabular;
   var aggregateFunc := Info.ParamAsString[0];
   var opCodes := Info.ParamAsScriptDynArray[1];
   var fromIndex := Info.ParamAsInteger[2];
   var toIndex := Info.ParamAsInteger[3];

   var expr := PrepareExprFromOpcode(tabular, opCodes);
   try
      expr.JITCompile;
      if aggregateFunc = 'sum' then begin
         Info.ResultAsFloat := expr.EvaluateAggregate(tegSum, fromIndex, toIndex);
      end else raise EdwsTabular.CreateFmt('Unsupported aggregate function "%s"', [ aggregateFunc ]);
   finally
      expr.Free;
   end;
end;

procedure TdwsTabularLib.dwsTabularClassesTabularDataMethodsEvaluateNewColumnEval(
  Info: TProgramInfo; ExtObject: TObject);
begin
   var tabular := Info.ScriptObj.ExternalObject as TdwsTabular;
   var opCodes := Info.ParamAsScriptDynArray[1];

   var expr := PrepareExprFromOpcode(tabular, opCodes);
   try
      expr.JITCompile;
      var column := tabular.AddColumn(Info.ParamAsString[0]);
      column.Add(expr.EvaluateAll);
   finally
      expr.Free;
   end;
end;

procedure TdwsTabularLib.dwsTabularClassesTabularDataMethodsExportToSeparatedEval(
  Info: TProgramInfo; ExtObject: TObject);
var
   wobs : TWriteOnlyBlockStream;
   columns : TdwsTabularColumns;
   separator, quote : String;
   separatorFirst, quoteFirst : Char;

   procedure WriteQuoted(const s : String);
   begin
      var buf := s;
      FastStringReplace(buf, quote, quote+quote);
      wobs.WriteString(quote + buf + quote);
   end;

   procedure Write(const s : String);
   var
      p : PChar;
   begin
      if s = '' then Exit;
      p := PChar(s);
      repeat
         if (p^ = separatorFirst) or (p^ = quoteFirst) then begin
            WriteQuoted(s);
            Exit;
         end;
         Inc(p);
      until p^ = #0;
      wobs.WriteString(s);
   end;

var
   buf : String;
begin
   var tabular := Info.ScriptObj.ExternalObject as TdwsTabular;
   var columnNames := Info.ParamAsScriptDynArray[0];

   quote := Info.ParamAsString[2];
   if separator <> '' then
      separatorFirst := separator[1]
   else separatorFirst := #0;

   separator := Info.ParamAsString[1];
   if quote <> '' then
      quoteFirst := quote[1]
   else quoteFirst := #0;

   wobs := TWriteOnlyBlockStream.AllocFromPool;
   try
      var nbCols := columnNames.ArrayLength;
      SetLength(columns, nbCols);
      for var i := 0 to nbCols-1 do begin
         columnNames.EvalAsString(i, buf);
         var col := tabular.ColumnByName(buf);
         if col = nil then
            raise EdwsTabular.CreateFmt('Unknown column "%s"', [ buf ]);
         columns[i] := col;
         if i > 0 then
            wobs.WriteString(separator);
         Write(buf);
      end;
      wobs.WriteCRLF;
      for var k := 0 to tabular.RowCount-1 do begin
         for var i := 0 to nbCols-1 do begin
            if i > 0 then
               wobs.WriteString(separator);
            Write(columns[i].Strings[k]);
         end;
         wobs.WriteCRLF;
      end;
      Info.ResultAsString := wobs.ToString;
   finally
      wobs.Free;
   end;
end;

end.
