unit MiniREST.Server.Base;

interface

uses SysUtils, Rtti, Generics.Defaults, MiniREST.Intf, MiniREST.Server.Intf,
  MiniREST.Controller.Intf, MiniREST.Controller.Base, MiniREST.Common, MiniREST.Attribute,
  Generics.Collections, SyncObjs, MiniREST.Controller.Security.Intf;

type
  TMiniRESTServerBase = class(TInterfacedObject, IMiniRESTServer) // Mover para outra unit
  strict private
    type
      TMiniRESTActionInfo = class(TInterfacedObject, IMiniRESTActionInfo)
      private
        FMapping : string;
        FMethod : TRttiMethod;
        FClass : TClass;
        FRequestMethod : TMiniRESTRequestMethod;
        FPermission : string;
        FIsFactory : Boolean;
        FFactory : IMiniRESTControllerFactory;
      public
        constructor Create(AMapping, APermission : string; AMethod : TRttiMethod; ARequestMethod : TMiniRESTRequestMethod; AClass : TClass; AFactory: IMiniRESTControllerFactory = nil);
        function GetClass: TClass;
        function GetMapping: string;
        function GetMethod: TRttiMethod;
        function GetRequestMethod: TMiniRESTRequestMethod;
        function GetPermission: string;
        function GetIsFactory: Boolean;
        function GetFactory: IMiniRESTControllerFactory;
      end;
  protected
    FControllerOtherwise: TClass;
    FControllers: TObjectDictionary<string,  IMiniRESTActionInfo>;
    FMiddlewares: TList<IMiniRESTMiddleware>;
    FRttiContext: TRttiContext;
    FLock: TObject;
    FSecurityController: TFunc<IMiniRESTSecurityController>;
    FLogger: IMiniRESTLogger;
    FUseOldLock: Boolean;
    procedure Lock;
    procedure Unlock;
    procedure FindController(AContext : IMiniRESTActionContext);
    procedure InternalAddController(AClass: TClass; AControllerFactory: IMiniRESTControllerFactory);
  public
    constructor Create(const AUseOldLock: Boolean = True);
    destructor Destroy; override;
    procedure AddController(AController: TClass); overload;
    procedure AddController(AControllerFactory: IMiniRESTControllerFactory); overload;
    procedure SetControllerOtherwise(AController: TClass);
    procedure SetSecurityController(AController: TFunc<MiniREST.Controller.Security.Intf.IMiniRESTSecurityController>);
    function GetPort: Integer; virtual; abstract;
    procedure SetPort(APort: Integer); virtual; abstract;
    function Start: Boolean; virtual; abstract;
    function Stop: Boolean; virtual; abstract;
    procedure AddMiddleware(AMiddleware: IMiniRESTMiddleware);
    function GetLogger: IMiniRESTLogger;
    procedure SetLogger(ALogger: IMiniRESTLogger);
  end;

  TMiniRESTQueryParamBase = class(TInterfacedObject, IMiniRESTQueryParam)
  private
    FName : string;
    FValue : string;
  public
    constructor Create(AName, AValue : string);
    function GetName: string;
    function GetValue: string;
  end;

implementation

uses MiniREST.Util, MiniREST.RequestInfo, MiniREST.ControllerOtherwise.Intf,
  MiniREST.JSON;

{ TMiniRESTServer }

procedure TMiniRESTServerBase.AddController(AController: TClass);
begin
  InternalAddController(AController, nil);
end;

procedure TMiniRESTServerBase.AddController(
  AControllerFactory: IMiniRESTControllerFactory);
begin
  InternalAddController(AControllerFactory.GetClass, AControllerFactory);
end;

procedure TMiniRESTServerBase.AddMiddleware(AMiddleware: IMiniRESTMiddleware);
begin
  FMiddlewares.Add(AMiddleware);
end;

constructor TMiniRESTServerBase.Create(const AUseOldLock: Boolean);
begin
  FLock := TObject.Create;
  FRttiContext := TRttiContext.Create;
  {$IFDEF VER310}
  FRttiContext.KeepContext;
  {$ENDIF}
  FControllers := TObjectDictionary<string, IMiniRESTActionInfo>.Create;
  FMiddlewares := TList<IMiniRESTMiddleware>.Create;
  FUseOldLock := AUseOldLock;
end;

destructor TMiniRESTServerBase.Destroy;
begin
  FControllers.Free;
  FMiddlewares.Free;
  {$IFDEF VER310}
  FRttiContext.DropContext;
  {$ENDIF}
  FLock.Free;
  inherited;
end;

procedure TMiniRESTServerBase.FindController(AContext: IMiniRESTActionContext);
var LRequestInfo: IMiniRESTRequestInfo;
    LMiniRESTActionInfo: IMiniRESTActionInfo;
    LController: TObject;
    LControllerIntf: IMiniRESTController;
    LControllerOtherwise: IMiniRESTControllerOtherwise; //{ TODO : Refatorar - POG!!}
    LActionContext: IMiniRESTActionContext;
    LMiddleware: IMiniRESTMiddleware;
    LObject: TObject;
    LIntfTemp: IInterface;
    LSecurityResponse: IMiniRESTSecurityResponse;
    LFoundMiniRESTActionInfo: Boolean;
begin
  { TODO : Implementar / Remover Dependencia Indy/ ServerBase }
  LFoundMiniRESTActionInfo := False;
  if FUseOldLock then
    Lock;
  LController := nil;
  try
    try
      if not FUseOldLock then
        Lock;
      for LMiddleware in FMiddlewares do
      begin
        if not LMiddleware.Process(AContext) then
          Exit;
      end;      
    finally
      if not FUseOldLock then
        Unlock;
    end;
    LRequestInfo := TMiniRESTRequestInfo.Create(AContext.GetURI, AContext.GetCommandType);
    try
      if not FUseOldLock then
        Lock;
      for LMiniRESTActionInfo in FControllers.Values do
      begin
        if LRequestInfo.IsMatch(LMiniRESTActionInfo.Mapping, LMiniRESTActionInfo.RequestMethod) then
        begin
          LFoundMiniRESTActionInfo := True;
          Break;        
        end;
      end;      
    finally
      if not FUseOldLock then
        Unlock;
    end;
    if LFoundMiniRESTActionInfo then
    begin      
      AContext.ActionInfo := LMiniRESTActionInfo;
      if Assigned(FSecurityController) and (FSecurityController <> nil) {and (not FSecurityController.HasPermission(AContext))} then
      begin
        LSecurityResponse := FSecurityController.HasPermission(AContext);
        if not LSecurityResponse.HasPermission then
        begin
          AContext.SetResponseContent('{"erro":"' + TMiniRESTJson.TratarJsonString(LSecurityResponse.PermissionErrorMessage) + '"}');
          AContext.SetResponseContentType(rtApplicationJson);
          AContext.SetResponseStatusCode(403);
          Exit;
        end;
      end;
      if LMiniRESTActionInfo.IsFactory then
        LController := LMiniRESTActionInfo.Factory.GetController
      else
        LController := LMiniRESTActionInfo.&Class.Create;
      if Supports(LController, IMiniRESTController, LControllerIntf) then
      begin
        LControllerIntf.InitController;
        LControllerIntf.SetLogger(GetLogger);
        LControllerIntf.SetActionContext(AContext);
        if (Length(LMiniRESTActionInfo.Method.GetParameters) = 1) and (LMiniRESTActionInfo.Method.GetParameters[0].ParamType.QualifiedName = 'MiniREST.Intf.IMiniRESTActionContext') then
          LMiniRESTActionInfo.Method.Invoke(TObject(LControllerIntf),[TValue.From<IMiniRESTActionContext>(AContext)])
        else
          LMiniRESTActionInfo.Method.Invoke(TObject(LControllerIntf),[]);
        if LMiniRESTActionInfo.IsFactory then
          LMiniRESTActionInfo.Factory.ClearFactory;        
        Exit;
      end
      else
      begin
        try
          if (Length(LMiniRESTActionInfo.Method.GetParameters) = 1) and (LMiniRESTActionInfo.Method.GetParameters[0].ParamType.QualifiedName = 'MiniREST.Intf.IMiniRESTActionContext') then
            LMiniRESTActionInfo.Method.Invoke(TObject(LController),[TValue.From<IMiniRESTActionContext>(AContext)])
          else
            raise Exception.Create('M�todo ' + LMiniRESTActionInfo.Method.Parent.Name + '.'+ LMiniRESTActionInfo.Method.Name + ' sem par�metro IMiniRESTActionContext.'); { TODO : Add logger }
          Exit;
        finally
          LController.Free;
        end;
      end;
    end;
    if FControllerOtherwise <> nil then
    begin
      LObject := FControllerOtherwise.Create;
      if Supports(LObject, IMiniRESTControllerOtherwise, LControllerOtherwise) then
        LControllerOtherwise.Action(AContext)
      else
      begin
        LObject.Free;
        raise Exception.Create('Classe ' + FControllerOtherwise.ClassName + ' n�o suporta interface IMiniRESTControllerOtherwise');
      end;
    end;
  finally
    if FUseOldLock then
      Unlock;
  end;
end;

function TMiniRESTServerBase.GetLogger: IMiniRESTLogger;
begin
  Result := FLogger;
end;

procedure TMiniRESTServerBase.InternalAddController(AClass: TClass;
  AControllerFactory: IMiniRESTControllerFactory);
var LType : TRttiType;
    LMethod : TRttiMethod;
    LAttribute : TCustomAttribute;
    LRequestAttribute : RequestMappingAttribute;
begin
  LType := FRttiContext.GetType(AClass);
  for LMethod in LType.GetMethods do
  begin
    for LAttribute in LMethod.GetAttributes do
    begin
      if LAttribute.ClassType = RequestMappingAttribute then
      begin
        LRequestAttribute := RequestMappingAttribute(LAttribute);
        FControllers.Add(LRequestAttribute.Mapping + '|' + IntToStr(Integer(LRequestAttribute.RequestMethod)), TMiniRESTActionInfo.Create(
        LRequestAttribute.Mapping, LRequestAttribute.Permission, LMethod, LRequestAttribute.RequestMethod, AClass, AControllerFactory));
      end;
    end;
  end;
end;

procedure TMiniRESTServerBase.Lock;
begin
  TMonitor.Enter(FLock);
end;

procedure TMiniRESTServerBase.SetControllerOtherwise(
  AController: TClass);
begin
  FControllerOtherwise := AController;
end;

procedure TMiniRESTServerBase.SetLogger(ALogger: IMiniRESTLogger);
begin
  FLogger := ALogger;
end;

procedure TMiniRESTServerBase.SetSecurityController(
  AController: TFunc<MiniREST.Controller.Security.Intf.IMiniRESTSecurityController>);
begin
  FSecurityController := AController;
end;

procedure TMiniRESTServerBase.Unlock;
begin
  TMonitor.Exit(FLock);
end;

{ TMiniRESTServer.TMiniRESTActionInfo }

constructor TMiniRESTServerBase.TMiniRESTActionInfo.Create(AMapping, APermission : string;
  AMethod: TRttiMethod; ARequestMethod : TMiniRESTRequestMethod; AClass: TClass;
  AFactory: IMiniRESTControllerFactory);
begin
  FMapping := AMapping;
  FMethod := AMethod;
  FClass := AClass;
  FRequestMethod := ARequestMethod;
  FPermission := APermission;
  FFactory := AFactory;
  FIsFactory := AFactory <> nil;
end;

function TMiniRESTServerBase.TMiniRESTActionInfo.GetClass: TClass;
begin
  Result := FClass;
end;

function TMiniRESTServerBase.TMiniRESTActionInfo.GetFactory: IMiniRESTControllerFactory;
begin
  Result := FFactory;
end;

function TMiniRESTServerBase.TMiniRESTActionInfo.GetIsFactory: Boolean;
begin
  Result := FIsFactory;
end;

function TMiniRESTServerBase.TMiniRESTActionInfo.GetMapping: string;
begin
  Result := FMapping;
end;

function TMiniRESTServerBase.TMiniRESTActionInfo.GetMethod: TRttiMethod;
begin
  Result := FMethod;
end;

function TMiniRESTServerBase.TMiniRESTActionInfo.GetPermission: string;
begin
  Result := FPermission;
end;

function TMiniRESTServerBase.TMiniRESTActionInfo.GetRequestMethod: TMiniRESTRequestMethod;
begin
  Result := FRequestMethod;
end;

{ TMiniRESTQueryParamBase }

constructor TMiniRESTQueryParamBase.Create(AName, AValue: string);
begin
  FName := AName;
  FValue := AValue;
end;

function TMiniRESTQueryParamBase.GetName: string;
begin
  Result := FName;
end;

function TMiniRESTQueryParamBase.GetValue: string;
begin
  Result := FValue;
end;

end.
